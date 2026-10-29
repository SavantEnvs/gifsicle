#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS gifsicle's own testie suite (test/*.testie) against the NORMAL-flag
# src/gifsicle + src/gifdiff that mayhem/build.sh produced. The tests compare gifsicle's output
# GIFs with expected output, so a no-op/exit(0) gifsicle fails them.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
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

for b in src/gifsicle src/gifdiff test/testie; do
  [ -x "$b" ] || { echo "test.sh: $b missing — mayhem/build.sh should have built it" >&2; emit_ctrf testie 0 1 0; exit 1; }
done

out=$(perl test/testie -p src -x fuzz test 2>&1); rc=$?
echo "$out" | tail -20
line=$(echo "$out" | grep -E '^testie: [0-9]+ successes?, [0-9]+ failures?' | tail -1)
if [ -z "$line" ]; then
  echo "test.sh: could not parse testie summary (rc=$rc)" >&2
  emit_ctrf testie 0 1 0; exit 1
fi
passed=$(echo "$line" | sed -E 's/^testie: ([0-9]+) success.*/\1/')
failed=$(echo "$line" | sed -E 's/.*, ([0-9]+) failure.*/\1/')
skipped=$(echo "$line" | sed -E 's/.*, ([0-9]+) skipped.*/\1/')
[ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
emit_ctrf testie "$passed" "$failed" "$skipped"
