#!/usr/bin/env bash
# Tests bin/sdd-devin against a fake devin executable in a throwaway git repo.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
SD="$here/../bin/sdd-devin"
tmp=$(mktemp -d)
cleanup() { for f in "$tmp"/repo/.superpowers/sdd/plan/devin-task-*/pid; do [ -f "$f" ] && pkill -s "$(cat "$f")" 2>/dev/null; done; rm -rf "$tmp"; }
trap cleanup EXIT

# Fake devin: records its argv, then behaves according to FAKE_MODE.
cat > "$tmp/fake-devin" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_ARGS"
pwd > "$FAKE_ARGS.cwd"
case "${FAKE_MODE:-done}" in
  done) echo "x" > feature.txt && git add feature.txt && git commit -qm "Task 1: feature"
        echo "Implemented."; echo "**STATUS: DONE**" ;;
  concerns) echo "STATUS: DONE_WITH_CONCERNS flaky test" ;;
  nostatus) echo "I did something." ;;
  sleep) sleep 30; echo "STATUS: DONE" ;;
  fail) echo "boom" >&2; exit 3 ;;
esac
FAKE
chmod +x "$tmp/fake-devin"
mkdir -p "$tmp/bin" && ln -s "$tmp/fake-devin" "$tmp/bin/devin"
export PATH="$tmp/bin:$PATH" FAKE_ARGS="$tmp/args"

repo="$tmp/repo"; mkdir -p "$repo/sub"
git -C "$repo" init -q && git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
ws="$repo/.superpowers/sdd/plan"; mkdir -p "$ws"
echo brief > "$ws/task-1-brief.md"; echo constraints > "$ws/constraints.md"; echo "fix X" > "$ws/findings.md"
base=(--task 1 --brief "$ws/task-1-brief.md" --report "$ws/task-1-report.md" --constraints "$ws/constraints.md" --workspace "$ws")
job_of() { sed -n 's/^JOB=//p' <<<"$1"; }

echo "input validation"
run_rc() { (cd "$repo/sub" && "$SD" "$@" >/dev/null 2>&1); echo $?; }
check "rejects a non-numeric task" test "$(run_rc start --task x "${base[@]:2}")" = 2
check "rejects a missing brief file" test "$(run_rc start --task 1 --brief "$ws/nope" "${base[@]:4}")" = 2
check "rejects a missing workspace" test "$(run_rc start "${base[@]:0:8}" --workspace "$tmp/nope")" = 2
check "rejects an option without a value" test "$(run_rc start "${base[@]}" --context)" = 2
check "rejects an unknown option" test "$(run_rc start "${base[@]}" --prompt hi)" = 2
check "rejects a path containing a newline" test "$(run_rc start "${base[@]}" --context "$ws/a
b")" = 2
check "rejects a non-numeric timeout" test "$(cd "$repo" && SDD_DEVIN_TIMEOUT=abc "$SD" start "${base[@]}" >/dev/null 2>&1; echo $?)" = 2
check "rejects running outside git" test "$(cd "$tmp" && "$SD" start "${base[@]}" >/dev/null 2>&1; echo $?)" = 2
check "wait rejects a non-job directory" test "$("$SD" wait "$tmp" 1 >/dev/null 2>&1; echo $?)" = 2
check "missing devin binary is reported" test "$(cd "$repo" && PATH=/usr/bin:/bin "$SD" start "${base[@]}" >/dev/null 2>&1; echo $?)" = 2
printf '#!/bin/sh\necho pwned > "%s/pwned"\n' "$tmp" > "$tmp/evil" && chmod +x "$tmp/evil"
job=$(cd "$repo" && SDD_DEVIN_BIN="$tmp/evil" "$SD" start "${base[@]}" | sed -n 's/^JOB=//p')
"$SD" wait "$job" 30 >/dev/null
check "SDD_DEVIN_BIN cannot redirect the wrapper to another executable" test ! -e "$tmp/pwned"
rm -rf "$job"

echo "successful job"
out=$(cd "$repo/sub" && "$SD" start "${base[@]}")
job=$(job_of "$out")
check "prints JOB under the workspace" test "$job" = "$ws/devin-task-1-1"
res=$("$SD" wait "$job" 30)
check "wait reports EXIT 0" contains "$res" "EXIT 0"
check "wait extracts the STATUS line without markdown" contains "$res" $'\nSTATUS: DONE\n'
check "devin ran at the repository root" test "$(cat "$FAKE_ARGS.cwd")" = "$repo"
args=$(cat "$FAKE_ARGS")
check "headless prompt-file mode" contains "$args" $'-p\n--prompt-file\n'"$job/prompt.md"
check "default model swe-2-high" contains "$args" $'--model\nswe-2-high'
check "default permission mode dangerous" contains "$args" $'--permission-mode\ndangerous'
check "workspace trust not required" contains "$args" $'--respect-workspace-trust\nfalse'
check "no sandbox by default" test "$(grep -c -- --sandbox "$FAKE_ARGS")" = 0
check "conversation exported into the job" contains "$args" "$job/conversation.atif"
prompt=$(cat "$job/prompt.md")
check "prompt points at the brief" contains "$prompt" "Read your task brief first: $ws/task-1-brief.md"
check "prompt asks to write the report" contains "$prompt" "4. Write the report file $ws/task-1-report.md"
check "prompt forbids committing the workspace" contains "$prompt" "Never commit anything under .superpowers/."
check "prompt ends with the STATUS contract" test "$(tail -n 1 "$job/prompt.md")" = "STATUS: NEEDS_CONTEXT <question>"
check "the commit landed" test "$(git -C "$repo" log -1 --format=%s)" = "Task 1: feature"

echo "fix round with context and options"
echo "use port 8080" > "$ws/ctx.md"
out=$(cd "$repo" && SDD_DEVIN_MODEL=swe-2-low SDD_DEVIN_SANDBOX=1 FAKE_MODE=concerns "$SD" start "${base[@]}" --context "$ws/ctx.md" --findings "$ws/findings.md")
job=$(job_of "$out")
check "a second job gets the next number" test "$job" = "$ws/devin-task-1-2"
res=$("$SD" wait "$job" 30)
check "DONE_WITH_CONCERNS is passed through" contains "$res" "STATUS: DONE_WITH_CONCERNS flaky test"
args=$(cat "$FAKE_ARGS")
check "model override" contains "$args" $'--model\nswe-2-low'
check "sandbox flag when enabled" contains "$args" "--sandbox"
prompt=$(cat "$job/prompt.md")
check "prompt scopes the fix to the findings" contains "$prompt" "Fix exactly the review findings in $ws/findings.md, and nothing else."
check "prompt appends to the report" contains "$prompt" "4. Append to the report file"
check "prompt references the controller context by path" contains "$prompt" "$ws/ctx.md"
check "model-written text is not inlined" test "$(grep -c 'use port 8080\|fix X' "$job/prompt.md")" = 0

echo "failures"
job=$(job_of "$(cd "$repo" && FAKE_MODE=nostatus "$SD" start "${base[@]}")")
res=$("$SD" wait "$job" 30)
check "missing STATUS falls back to BLOCKED" contains "$res" "STATUS: BLOCKED no STATUS line"
job=$(job_of "$(cd "$repo" && FAKE_MODE=fail "$SD" start "${base[@]}")")
res=$("$SD" wait "$job" 30)
check "non-zero exit is reported" contains "$res" "EXIT 3"
check "stderr tail is shown" contains "$res" "boom"
job=$(job_of "$(cd "$repo" && SDD_DEVIN_TIMEOUT=1 FAKE_MODE=sleep "$SD" start "${base[@]}")")
res=$("$SD" wait "$job" 30)
check "timeout kills the job with 124" contains "$res" "EXIT 124"

echo "running and stop"
job=$(job_of "$(cd "$repo" && FAKE_MODE=sleep "$SD" start "${base[@]}")")
res=$("$SD" wait "$job" 1)
check "wait returns RUNNING before the deadline" contains "$res" "RUNNING"
sid=$(cat "$job/pid")
check "the job runs in its own session" test -n "$(pgrep -s "$sid")"
"$SD" stop "$job" >/dev/null
for _ in 1 2 3 4 5; do [ -z "$(pgrep -s "$sid")" ] && break; sleep 1; done
check "stop ends devin and its timeout wrapper" test -z "$(pgrep -s "$sid")"

echo "relative paths"
job=$(job_of "$(cd "$repo" && "$SD" start --task 2 --brief .superpowers/sdd/plan/task-1-brief.md --report .superpowers/sdd/plan/r.md --constraints .superpowers/sdd/plan/constraints.md --workspace .superpowers/sdd/plan)")
check "the job path is absolute" test "$job" = "$ws/devin-task-2-1"
res=$("$SD" wait "$job" 30)
check "a job started with relative paths completes" contains "$res" "EXIT 0"
check "the prompt carries absolute paths" contains "$(cat "$job/prompt.md")" "Read your task brief first: $ws/task-1-brief.md"

finish
