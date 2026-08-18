/*
 * mayhem/pforth_fuzzer.c — in-process libFuzzer harness for pForth.
 *
 * The old integration fuzzed the raw CLI (`pforth_standalone @@`), which Mayhem's commit-image
 * build could not instrument (0 edges, "Run Failed"). pForth's #226 added a public embedding API
 * — pfInitialize()/pfInterpretText()/pfTerminate() — so we drive the interpreter directly, over
 * the SAME code path the CLI exercises (ffInterpret over the terminal input buffer), but in-process
 * so libFuzzer/Mayhem coverage instrumentation applies.
 *
 * The interpreter (dictionary + task) is initialized ONCE for the process and reused across inputs
 * (the conventional persistent-libFuzzer shape). Per-input pfInitialize()/pfTerminate() was tried
 * first but rebuilt/loaded the static dictionary and re-created the task on every execution, making
 * the harness far too slow (~70 exec/s under ASan) for a run to finish its coverage/triage phase.
 * A word defined by one input therefore persists into later inputs; if the dictionary fills,
 * pfInterpretText() returns a Forth THROW (handled, non-fatal) rather than crashing.
 *
 * The standalone reproducer built from this same file links the run-once driver, so a POV is
 * replayed as a single input in a fresh process (init-once == that one input) — naturally reproducible.
 *
 * pfInterpretText copies the text into the fixed terminal input buffer and rejects text longer than
 * TIB_SIZE (256), so the input is capped accordingly.
 *
 * ---- hangs: bounded by the runner, not by this harness ----
 *
 * pForth's inner interpreter (csrc/pf_inner.c) is a plain threaded-code dispatch loop with no
 * instruction counter, no interrupt/yield check and no step limit that an embedder can set through
 * the public API. A guest program with an unconditional loop (`: L BEGIN AGAIN ; L`), a DO...LOOP
 * with a huge count or a long `MS` delay therefore runs until something outside the interpreter
 * stops it. That is the runner's job: libFuzzer's -timeout and Mayhem's per-test timeout (the
 * Mayhemfile `timeout:`) stop such an input and report it as a timeout, i.e. a hang finding. The
 * harness installs no timer and no signal handler, so libFuzzer keeps sole ownership of SIGALRM, and
 * any crash an input reaches within the runner's limit is reported.
 *
 * Recursion/stack depth is NOT separately capped here: pForth's own data/return/float stacks are
 * fixed-size C arrays (csrc/pf_core.c CreateTaskContext) with only a small STACK_SAFETY headroom and
 * NO bounds check on push/pop (PUSH_DATA_STACK/POP_DATA_STACK, csrc/pf_guts.h) -- an overflow is a
 * genuine out-of-bounds write that ASan is expected to catch, which is exactly the class of bug this
 * fuzz target exists to find, not something to mask.
 *
 * NO HOST FILESYSTEM ACCESS: the fuzz build additionally compiles every pForth translation unit with
 * -DPF_NO_FILEIO (see mayhem/build.sh), which swaps in pForth's own safe stub file-I/O backend
 * (csrc/pf_io.c) for OPEN-FILE/CREATE-FILE/DELETE-FILE/WRITE-FILE/READ-FILE/(RENAME-FILE)/
 * INCLUDE-FILE -- every one of those Forth words becomes a no-op that returns a failure code without
 * touching a real file, so untrusted Forth source fed to this harness cannot read, write, create, or
 * delete anything on the container filesystem. (The project's OWN test suite, run by mayhem/test.sh
 * against a SEPARATE normal-flags build that does NOT define PF_NO_FILEIO, still exercises real file
 * I/O via t_file.fth -- only the fuzz/standalone objects are neutered.)
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "pforth.h"

/* TIB_SIZE is 256 (csrc/pf_guts.h); pfInterpretText aborts on longer text. */
#define PFORTH_MAX_INPUT 256

static int g_ready = -1;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    char buf[PFORTH_MAX_INPUT + 1];
    ExecToken entryPoint = 0;

    if (g_ready < 0) {
        pfSetQuiet(1);
        g_ready = (pfInitialize(NULL, 0, &entryPoint) == 0) ? 1 : 0;
    }
    if (g_ready != 1) {
        /* Static dictionary failed to load — nothing to fuzz. */
        return 0;
    }

    if (size > PFORTH_MAX_INPUT) {
        size = PFORTH_MAX_INPUT;
    }
    memcpy(buf, data, size);
    buf[size] = '\0';

    pfInterpretText(buf);
    return 0;
}
