# Minimal assertion helpers shared by the shell tests.
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -z "${2-}" ] || printf '%s\n' "$2" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
finish() { echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]; }
