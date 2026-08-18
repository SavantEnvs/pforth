#!/usr/bin/env bash
#
# mayhem/test.sh — RUN pForth's own test suite (already built by mayhem/build.sh).
#
# Upstream's suite is `make test` in platforms/unix/Makefile: it runs seven Forth test
# scripts under fth/ with `pforth_standalone -q <script>`. Each script uses fth/t_tools.fth
# (T{ ... }T{ ... }T known-answer assertions); }TEST prints "  N passed,  M failed." and a
# failing suite makes pforth exit with code 40 (TEST_EXIT_FAILURE). We run the same seven
# scripts against the pre-built normal-flags binary and aggregate the per-script assertion
# counts into CTRF. A script that emits no "passed," marker (e.g. a neutered exit(0) binary)
# counts as failed.
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

BIN="$SRC/mayhem/out/pforth_standalone_test"
if [ ! -x "$BIN" ]; then
  echo "FATAL: $BIN missing — mayhem/build.sh must build the test binary" >&2
  emit_ctrf pforth-make-test 0 1
  exit 1
fi

# The exact script list from `make test` (platforms/unix/Makefile).
SCRIPTS="t_corex.fth t_strings.fth t_locals.fth t_alloc.fth t_floats.fth t_file.fth"

total_passed=0
total_failed=0
cd "$SRC/fth"
for t in $SCRIPTS; do
  echo "=== $t ==="
  out="$("$BIN" -q "$t" 2>&1)"; rc=$?
  echo "$out"
  p="$(printf '%s\n' "$out" | grep -oE '[0-9]+ +passed' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')"
  f="$(printf '%s\n' "$out" | grep -oE '[0-9]+ +failed' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')"
  total_passed=$(( total_passed + p ))
  total_failed=$(( total_failed + f ))
  if [ "$rc" -ne 0 ] || [ "$p" -eq 0 ]; then
    # crashed, exited TEST_EXIT_FAILURE, or produced no assertion output at all
    echo ">>> $t FAILED (rc=$rc, passed=$p, failed=$f)" >&2
    [ "$f" -gt 0 ] || total_failed=$(( total_failed + 1 ))
  fi
done

# t_include.fth (the 7th `make test` script) deliberately triggers a caught INCLUDE error,
# after which pForth prints the error diagnostics and stops emitting the }TEST summary — so
# (like upstream) we can't count assertions here. Instead assert the golden diagnostic output:
# the interpreter must report the undefined word at the right line AND exit 0.
echo "=== t_include.fth ==="
out="$("$BIN" -q t_include.fth 2>&1)"; rc=$?
echo "$out"
if [ "$rc" -eq 0 ] \
   && printf '%s\n' "$out" | grep -q 'INCLUDE error on line #4' \
   && printf '%s\n' "$out" | grep -q 'BADWORD  ? - unrecognized word!'; then
  total_passed=$(( total_passed + 1 ))
else
  echo ">>> t_include.fth FAILED (rc=$rc, golden diagnostics missing)" >&2
  total_failed=$(( total_failed + 1 ))
fi

emit_ctrf pforth-make-test "$total_passed" "$total_failed"
