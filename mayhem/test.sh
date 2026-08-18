#!/usr/bin/env bash
#
# mayhem/test.sh — RUN pForth's own test suite (built by mayhem/build.sh) and decide every verdict
# here, in this script.
#
# The suite is upstream's `make test` (platforms/unix/Makefile): seven Forth scripts (t_corex,
# t_strings, t_locals, t_alloc, t_floats, t_file, t_include) of T{ code }T{ expected }T
# assertions. Four rules keep the patched program from grading itself:
#
#  1. Pinned test files. The scripts, the files they include and the assertion framework are
#     copies under mayhem/oracle/ (which rlenv removes from the agent's tree). The tree's own
#     fth/t_*.fth are never used: a patch can edit those (#1460). The copies are checked against
#     the SHA-256 list below before anything runs, because patched code runs during the build
#     (the bootstrap interpreter makes the dictionary) and could rewrite them. Any mismatch fails
#     every test.
#  2. The program never gets the right answers (#878). Before pForth reads a script, this script
#     removes the expected half of every assertion with mayhem/oracle/strip.awk ("T{ 1 2 + }T{ 3
#     }T" becomes "T{ 1 2 + }T{ }T") and checks the result against a second SHA-256 list. The
#     answers are only in mayhem/oracle/expected.txt, which is read into memory here before any
#     pForth process starts and is never copied to where a pForth process runs. Ten t_strings
#     results are string addresses, which change from run to run: for those, strip.awk adds
#     words to the code half that turn the address into an offset, so every answer is a number.
#  3. Verdicts come from this script (#878). mayhem/oracle/t_tools.fth replaces upstream's
#     framework: it keeps no tally and prints, for each assertion, only what the code computed:
#     "@@ <nonce> <seq> A <n> : <a1> .. <an>" (top of stack first). Each A list is compared with
#     expected.txt here; a missing, repeated or malformed record fails that assertion. Nothing
#     else the program prints is counted. <nonce> is a new random number for each process that
#     marks the record lines. The program reads it (it is the first line of its input), so it is
#     not what stops forging: a patch that rewrites the records or the input has no right answer
#     to copy into them.
#  4. Most assertions also run on the GRADED binary (/mayhem/pforth_fuzzer). Each script line is
#     one libFuzzer input, run in order in one process, so the harness's single interpreter keeps
#     the definitions and the stack from line to line. A patch that disables code only in the fuzz
#     build (PF_NO_FILEIO, sanitizer or optimisation checks) fails these. Column 4 of
#     expected.txt says where each assertion runs:
#       G: on the graded binary AND on the test binary; both must give the right answer.
#       W: on the test binary AND on mayhem/out/pforth_fuzzer_twin, which mayhem/build.sh compiles
#          with the graded binary's exact compile line plus -fsanitize-recover=undefined (UBSan
#          prints its report and carries on; nothing else differs, no runtime options). W is the
#          DO +LOOP and 1+/1- wrap-around tests (t_corex #75-92): they reach real signed
#          overflows in csrc/pf_inner.c that stop the graded binary. The twin runs the whole of
#          t_corex, one line per input, like the graded run.
#       F: on the test binary only. Nothing graded-flags can run these: t_file (94, file I/O,
#          which the fuzz build stubs out), t_include's INCLUDE check (same reason), SOURCE-ID
#          (t_corex #45-46; it differs for text the harness passes in) and the locals list
#          spread over several lines (t_locals #9: one line per input leaves `{` unclosed, and
#          Word() in csrc/pf_words.c then reads past its 256-byte buffer, an ASan error that
#          even the twin cannot get past).
#     "S <modes> <script> <first> <last> <next>" lines in expected.txt name the script lines that
#     the graded (G) and/or twin (W) run leaves out, and the assertion number to continue from.
#     mayhem/oracle/t_bounds.fth (written for this script, not from upstream) adds G assertions
#     for 1+, 1-, 2+, 2- and +LOOP next to MIN-INT/MAX-INT that do not overflow, so the graded
#     binary itself checks those words too.
#
# Limits: the answers are not secret from whoever writes a patch (upstream's fth/t_*.fth are in
# the tree), so a patch that recognises these particular tests and returns their answers is not
# caught, nor is one that tells these runs apart from fuzzing while it runs. t_corex's four GD9
# assertions (lines 294-297) pass their expected count as an argument in the code half
# (upstream's design), so that number is in the program's input.
#
# Tests: one per assertion (383), plus one per process (16) that must exit 0 and print the
# "@@ <nonce> END" line that T.END writes after the last script line.
# `-detect_leaks=0` is a libFuzzer flag on this command line only. Without it libFuzzer runs any
# input that allocated memory a second time (its leak check), which would print records twice.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TOOL=pforth-make-test
TESTBIN="$SRC/mayhem/out/pforth_standalone_test"   # project's normal-flags build (file mode)
FUZZBIN=/mayhem/pforth_fuzzer                       # the graded libFuzzer binary
TWINBIN="$SRC/mayhem/out/pforth_fuzzer_twin"        # graded flags + -fsanitize-recover=undefined
SCRIPTS="t_corex t_strings t_locals t_alloc t_floats t_file t_include t_bounds"
GRADED_SCRIPTS="t_corex t_strings t_locals t_alloc t_floats t_include t_bounds"
TWIN_SCRIPTS="t_corex"
HELPERS="t_load_undef.fth t_required_helper1.fth t_required_helper2.fth"   # INCLUDEd, no assertions
RUNS=16              # 8 test-binary runs + 7 graded-binary runs + 1 twin run
EXPECTED_TESTS=399   # 383 assertions + 16 runs

# SHA-256 of every pinned file. These are the only files read from mayhem/oracle/.
ORACLE_SHA256='
4eae14bf5fcb3d165b1731bfd335ec22d64eede8cc07371fb993aeac991a836d  expected.txt
fa41b46806300f104840372d348d4ce860bf60fe135ca7af41d6a39d8f27fa83  strip.awk
0d573432046b0f7e35b374bc6c4c634584f5d5731d6890993fbfe0704530dab0  t_alloc.fth
a11fd7c0e62e05ce400c3aabf1a2059c31f65e6650fac6f8154dc3ff6c2e1945  t_corex.fth
1ccc85af7193db202d2b0747648b035a419701c8bf54008115dfb721b288a3b5  t_file.fth
d37aa5a473f93bf72eb4d4eccc2db17f9032b1baa6a5cb6a3688ad0720bf6e7b  t_floats.fth
5a4e6dcf2d11898a4412e3ab3984fcd88f2e5163854ac107b54c694bfa29bf6f  t_include.fth
495f5c18de9ac8b1bc67db7b356118761f36486707f943627e17d94a0ee29ba3  t_load_undef.fth
49d50cd31c46e4ca6d5d180c624c03441ce095ba6ebc690f0331a08ee7df6734  t_locals.fth
b09d273fb8a8afa1438c6f8bc0a43a66e02a171d6f9e0d413c8777c58e126ba3  t_required_helper1.fth
b09d273fb8a8afa1438c6f8bc0a43a66e02a171d6f9e0d413c8777c58e126ba3  t_required_helper2.fth
e72930ceb2892915cdcb24b06d86be6878171b930cfec33abf87bba9fb53969b  t_strings.fth
255ebac356171ce4670d1c167137ae9f63b263a2905f7efeea1e09f62fd71603  t_tools.fth
a730bb2a5653c4212529b013cf16522381ee3ab277a27b61298fb363228be132  t_bounds.fth
'
# SHA-256 of each script after mayhem/oracle/strip.awk: exactly the text pForth is given.
STRIPPED_SHA256='
534f5d7fff7f384289c4da837618f346b3597e83fd2001a5df0eb9a21a2f41da  t_corex.fth
6547c96a7ae83338b558bca0fc2509921f957389bb707825cd0ff53733d77bdc  t_strings.fth
d975bd55da9e9a004677fa2b7e9d2cb97bf87031b772c7ce8945e4b87f8e5565  t_locals.fth
9f75b00fadcbc1c25dbb1c3d16d1ca264847a1314319812d8fb6ebf44122620f  t_alloc.fth
bd4ddb855d38e2998d69e4a79e7b62a8f3ca675b92745d76b1c91b02ce6147ec  t_floats.fth
2247104f1426442bf59d516dea8b3ca2bb5de6124bb0fddf3819e5fe49275f9b  t_file.fth
f138d04e6564e191836f9de9bf2f841e72a1bbda6f80ce18e2be1ece0434d923  t_include.fth
fab3d15b3a598594f48b3b13f25721415f6844cdbca9654156274707cd107a13  t_bounds.fth
'

fail_all() {   # fail_all <reason> : nothing could be checked
  echo "FATAL: $1" >&2
  emit_ctrf "$TOOL" 0 "$EXPECTED_TESTS"
  exit 1
}

for b in "$TESTBIN" "$FUZZBIN" "$TWINBIN"; do
  [ -x "$b" ] || fail_all "$b missing (mayhem/build.sh must build it)"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pforth-test.XXXXXX")" || fail_all "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

check_sums() {   # check_sums <dir> <sha256 list> : every file in the list is in <dir> and matches
  ( cd "$1" && printf '%s\n' "$2" | awk 'NF == 2' | sha256sum --check --strict --quiet - ) >&2
}

# Private copy of the pinned files, checked after copying, so the checked bytes are the ones used.
PIN="$WORK/pinned"
mkdir "$PIN"
for f in $(printf '%s\n' "$ORACLE_SHA256" | awk 'NF == 2 { print $2 }'); do
  cp "$SRC/mayhem/oracle/$f" "$PIN/$f" || fail_all "mayhem/oracle/$f missing"
done
check_sums "$PIN" "$ORACLE_SHA256" || fail_all "mayhem/oracle/ does not match the SHA-256 list in mayhem/test.sh"

# The answers, read into memory before any pForth process runs.
EXPECTED="$(cat "$PIN/expected.txt")"
n_assert="$(printf '%s\n' "$EXPECTED" | awk '$1 == "T"' | wc -l)"
[ $(( n_assert + RUNS )) -eq "$EXPECTED_TESTS" ] || fail_all "expected.txt has $n_assert assertions"

# $FEED holds everything a pForth process is given: the stripped scripts, t_tools.fth and the
# helper files. None of it has a right answer in it. The verbatim scripts and expected.txt are
# removed from $WORK before the first pForth process starts.
FEED="$WORK/feed"
mkdir "$FEED"
for s in $SCRIPTS; do
  awk -v S="$s" -f "$PIN/strip.awk" "$PIN/expected.txt" "$PIN/$s.fth" > "$FEED/$s.fth" || fail_all "strip.awk failed on $s.fth"
done
for f in t_tools.fth $HELPERS; do cp "$PIN/$f" "$FEED/$f"; done
FEED_SHA256="$STRIPPED_SHA256$(printf '%s\n' "$ORACLE_SHA256" | awk -v H="t_tools.fth $HELPERS" 'NF == 2 && index(" " H " ", " " $2 " ")')"
check_sums "$FEED" "$FEED_SHA256" || fail_all "stripped scripts do not match the SHA-256 list in mayhem/test.sh"
rm -rf "$PIN"

nonce() { od -An -N4 -tu4 /dev/urandom | tr -d ' \n'; }

# run_file_mode <script> : the test binary runs the stripped script as a file, like `make test`.
# Writes $WORK/F.<script>.rec (records, nonce removed), .out (all output) and .ok (run passed).
# The run directory gets the $FEED files only (checked again, in case an earlier run changed them).
run_file_mode() {
  local s="$1" d="$WORK/F.$1" n rc
  n="$(nonce)"; : > "$d.rec"
  mkdir "$d" && cp "$FEED"/* "$d/"
  printf '%s CONSTANT ORACLE-NONCE\nINCLUDE t_tools.fth\nINCLUDE %s.fth\nT.END\n' "$n" "$s" > "$d/oracle_run.fth"
  check_sums "$d" "$FEED_SHA256" || { echo ">>> $s: a stripped script changed before the run" >&2; return; }
  ( cd "$d" && "$TESTBIN" -q oracle_run.fth ) > "$d.out" 2>&1 < /dev/null; rc=$?
  grep -a "^@@ $n [0-9]" "$d.out" | cut -d' ' -f3- > "$d.rec"
  if [ "$rc" -eq 0 ] && grep -aqx "@@ $n END" "$d.out"; then : > "$d.ok"
  else echo ">>> $s (test binary): exit $rc$(grep -aqx "@@ $n END" "$d.out" || echo ', did not reach the end')" >&2; fi
}

# run_lines <mode> <binary> <script> : a libFuzzer binary (G: the graded binary, W: the twin) gets
# t_tools.fth and the stripped script, one line per input file, in one process. Lines named by
# "S <modes> <script> <first> <last> <next>" with <mode> in <modes> are left out and followed by
# "<next> T-SEQ !" so the assertion numbers stay the same as in file mode.
# Writes $WORK/<mode>.<script>.rec, .out, .err and .ok like run_file_mode. The fuzz build's
# FLUSHEMIT is a no-op (PF_NO_FILEIO), so a crash in one of these runs loses the records still
# buffered: the script's assertions then fail on this binary (the test-binary run still counts).
run_lines() {
  local m="$1" bin="$2" s="$3" d="$WORK/$1.$3" n rc
  n="$(nonce)"; : > "$d.rec"
  check_sums "$FEED" "$FEED_SHA256" || { echo ">>> $s: a stripped script changed before the $m run" >&2; return; }
  mkdir -p "$d/in"
  { printf '%s CONSTANT ORACLE-NONCE\n' "$n"
    cat "$FEED/t_tools.fth"
    printf '%s\n' "$EXPECTED" | awk -v M="$m" -v S="$s" '
      FNR == NR { if ($1 == "S" && index($2, M) && $3 == S) { k++; a[k] = $4; b[k] = $5; q[k] = $6 } next }
      { skip = 0; for (i = 1; i <= k; i++) if (FNR >= a[i] && FNR <= b[i]) skip = 1
        if (!skip) print
        for (i = 1; i <= k; i++) if (FNR == b[i]) print q[i] " T-SEQ !" }' - "$FEED/$s.fth"
    echo T.END
  } | awk -v D="$d/in" '{ f = sprintf("%s/%05d", D, NR); print > f; close(f) }'
  "$bin" -detect_leaks=0 "$d"/in/* > "$d.out" 2> "$d.err" < /dev/null; rc=$?
  grep -a "^@@ $n [0-9]" "$d.out" | cut -d' ' -f3- > "$d.rec"
  if [ "$rc" -eq 0 ] && grep -aqx "@@ $n END" "$d.out"; then : > "$d.ok"
  else
    echo ">>> $s ($m run, $bin): exit $rc$(grep -aqx "@@ $n END" "$d.out" || echo ', did not reach the end')" >&2
    { grep -a -m2 -E 'runtime error|ERROR: AddressSanitizer' "$d.err"; grep -a '^Running: ' "$d.err" | tail -1; } >&2
  fi
}

for s in $SCRIPTS; do run_file_mode "$s"; done
for s in $GRADED_SCRIPTS; do run_lines G "$FUZZBIN" "$s"; done
for s in $TWIN_SCRIPTS; do run_lines W "$TWINBIN" "$s"; done

# "D <script> <seq> <text>": the assertion also needs <text> in the script's test-binary output
# (t_include: the INCLUDE error report for the undefined word).
printf '%s\n' "$EXPECTED" | awk '$1 == "D"' | while read -r _ s q text; do
  grep -aqF -- "$text" "$WORK/F.$s.out" || echo "$s $q"
done > "$WORK/golden.miss"

# "T <script> <seq> <tier> <n> <v1> .. <vn>": the record must give exactly n results equal to
# v1..vn (top of stack first), compared as strings.
recs=()
for s in $SCRIPTS; do recs+=("$WORK/F.$s.rec"); done
for s in $GRADED_SCRIPTS; do recs+=("$WORK/G.$s.rec"); done
for s in $TWIN_SCRIPTS; do recs+=("$WORK/W.$s.rec"); done
read -r a_pass a_fail < <(printf '%s\n' "$EXPECTED" | awk '
  function check(kind, s, q, n,   k, t, m, i) {
    k = kind SUBSEP s SUBSEP q
    if (!(k in cnt)) return kind ": no record"
    if (cnt[k] > 1) return kind ": " cnt[k] " records"
    m = split(rec[k], t, " ")
    if (t[2] != "A" || t[3] !~ /^[0-9]+$/ || t[4] != ":" || m != 4 + t[3]) return kind ": malformed record: " rec[k]
    if (t[3] + 0 != n + 0) return kind ": " t[3] " results, want " n
    for (i = 1; i <= n; i++) if (t[4 + i] "" != $(5 + i) "") return kind ": result " i " = " t[4 + i] ", want " $(5 + i)
    return ""
  }
  FILENAME != "-" {
    f = FILENAME; sub(/.*\//, "", f)
    if (f == "golden.miss") { miss[$1 SUBSEP $2] = 1; next }
    split(f, p, "."); k = p[1] SUBSEP p[2] SUBSEP $1; cnt[k]++; rec[k] = $0; next
  }
  $1 == "T" {
    why = check("F", $2, $3, $5)
    if (why == "" && ($4 == "G" || $4 == "W")) why = check($4, $2, $3, $5)
    else if (why == "" && $4 != "F") why = "unknown tier " $4
    if (why == "" && (($2 SUBSEP $3) in miss)) why = "F: expected INCLUDE error report missing"
    if (why == "") pass++
    else { fail++; if (shown++ < 40) printf "FAIL %s #%d [%s] %s\n", $2, $3, $4, why > "/dev/stderr" }
  }
  END { print pass + 0, fail + 0 }' "$WORK/golden.miss" "${recs[@]}" -)

r_pass=0; r_fail=0
for s in $SCRIPTS; do
  if [ -e "$WORK/F.$s.ok" ]; then r_pass=$(( r_pass + 1 )); else r_fail=$(( r_fail + 1 )); fi
done
for s in $GRADED_SCRIPTS; do
  if [ -e "$WORK/G.$s.ok" ]; then r_pass=$(( r_pass + 1 )); else r_fail=$(( r_fail + 1 )); fi
done
for s in $TWIN_SCRIPTS; do
  if [ -e "$WORK/W.$s.ok" ]; then r_pass=$(( r_pass + 1 )); else r_fail=$(( r_fail + 1 )); fi
done
echo "assertions: ${a_pass:-0} passed, ${a_fail:-0} failed (of $n_assert); runs: $r_pass passed, $r_fail failed (of $RUNS)"

passed=$(( ${a_pass:-0} + r_pass ))
failed=$(( EXPECTED_TESTS - passed ))
emit_ctrf "$TOOL" "$passed" "$failed"
