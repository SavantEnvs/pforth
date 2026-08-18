# pforth — known findings

Found during integration by hand-testing the bounding story required for a Forth interpreter
(unconditional native loops and unbounded recursion — see the harness header comment in
`mayhem/pforth_fuzzer.c`), not by an actual fuzzing campaign yet. Kept here and NOT in
`testsuite/`: seeds are replayed on every run, and this reproducer aborts on every replay by design.

Reproduce (`pforth_fuzzer-standalone` is produced by `mayhem/build.sh`):

```
/mayhem/pforth_fuzzer-standalone mayhem/pforth/known-findings/return-stack-overflow-recurse.fth
```

---

## 1. `return-stack-overflow-recurse.fth` — heap-buffer-overflow (return-stack overflow), unbounded `RECURSE`

```
: R RECURSE ; R
```

```
==ERROR: AddressSanitizer: heap-buffer-overflow ... WRITE of size 8
    #0 pfCatch          csrc/pf_inner.c:354   (M_R_PUSH(InsPtr) — return-stack push)
    #1 FindAndCompileOrExecute / ffInterpret   csrc/pfcompil.c:862
0x... is located 8 bytes before 4096-byte region [...]
    allocated by pfCreateTask  csrc/pf_core.c:165  (td_ReturnLimit, DEFAULT_RETURN_DEPTH=512 cells)
```

**Cause — the return stack has a fixed size and NO overflow check on push.** `pfCreateTask`
(`csrc/pf_core.c:149`) allocates the return stack as a fixed `DEFAULT_RETURN_DEPTH` (512 cells = 4096
bytes on a 64-bit build) buffer; `td_ReturnPtr` starts at `td_ReturnBase` (the high end) and is
decremented on every push. The push itself, `M_R_PUSH` (used by `pfCatch` when threading into a
secondary word, `csrc/pf_inner.c:354`), unconditionally writes `*(--td_ReturnPtr) = value` with no
comparison against `td_ReturnLimit` — even though the codebase already defines
`THROW_STACK_OVERFLOW` (`csrc/pf_guts.h:403`) for exactly this condition, nothing raises it here.
Each level of Forth-level recursion (`RECURSE`, or any colon word that calls another colon word)
consumes one return-stack cell, so a self-recursive definition with no base case
(`: R RECURSE ; R`) walks straight off the low end of the buffer after 512 calls — a genuine
out-of-bounds heap write, not merely "a lot of stack usage." Note that the naive `: R R ; R` does
NOT reproduce this: standard Forth colon definitions aren't found in the dictionary until `;`
completes them, so a literal self-reference by name resolves to "undefined word" instead of
recursing — `RECURSE` (or a mutually-recursive pair via forward `DEFER`) is required to trigger it.

**Impact.** Out-of-bounds heap write of a return address, fully attacker-controlled in the sense
that the recursion depth (and thus how far past the buffer the write lands) is dictated entirely by
the input Forth source, on the core inner-interpreter dispatch path (every non-primitive word call
goes through this code). This is the kind of corruption a hardened allocator or a slightly different
heap layout could turn into a controlled write rather than a clean crash.

**Fix direction (not applied — upstream file, out of scope for this additive integration):** check
`td_ReturnPtr` against `td_ReturnLimit` (with the same `STACK_SAFETY` headroom already used for the
data/float stacks) before decrementing in `M_R_PUSH`, and `M_THROW(THROW_STACK_OVERFLOW)` on
violation — mirroring the check that protects the data stack's `NUMBER?`/`ffFind` overflow paths
elsewhere in `pfcompil.c`.

**Bounding note.** This is a fast crash (ASan aborts in well under a second), not a hang, so the
runner's per-test timeout never comes into play (the harness has no timer of its own; see
`mayhem/pforth_fuzzer.c`) — it is exactly the class of finding the fuzz target exists to surface, and
is expected to keep surfacing (deduped) once real fuzzing runs.
