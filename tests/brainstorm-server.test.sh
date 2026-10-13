#!/usr/bin/env bash
# Tests that the brainstorm server's default session directory is created safely.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
S="$here/../skills/brainstorming/scripts"
dirs=()
cleanup() { for d in "${dirs[@]}"; do bash "$S/stop-server.sh" "$d" >/dev/null 2>&1; done; }
trap cleanup EXIT

session_dir() { jq -r '.screen_dir // empty' <<<"$1" | sed 's|/content$||'; }
echo "default session directory"
out1=$(bash "$S/start-server.sh" --idle-timeout-minutes 1); d1=$(session_dir "$out1"); dirs+=("$d1")
out2=$(bash "$S/start-server.sh" --idle-timeout-minutes 1); d2=$(session_dir "$out2"); dirs+=("$d2")
check "the server starts and reports its directory" test -n "$d1" -a -d "$d1"
check "the name has a random suffix, not the pid and time" bash -c '[[ "$(basename "$1")" =~ ^brainstorm-[A-Za-z0-9]{10}$ ]]' _ "$d1"
check "two sessions get different directories" test "$d1" != "$d2"
check "the directory is owner-only" test "$(stat -c %a "$d1" 2>/dev/null || stat -f %Lp "$d1")" = 700
check "the directory belongs to the current user" test -O "$d1"
bash "$S/stop-server.sh" "$d1" >/dev/null 2>&1
check "stop-server removes the /tmp session directory" test ! -e "$d1"

finish
