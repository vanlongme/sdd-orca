#!/usr/bin/env bash
# Runs every test in this directory. Requires bash, git, jq, node >= 18 and procps (pgrep/pkill).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rc=0
for t in "$here"/*.test.sh; do echo "== $(basename "$t")"; bash "$t" || rc=1; done
for t in "$here"/*-dryrun.mjs; do echo "== $(basename "$t")"; node "$t" || rc=1; done
[ "$rc" = 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit "$rc"
