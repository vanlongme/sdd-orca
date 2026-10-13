#!/usr/bin/env bash
# Tests hooks/orca-tabs and hooks/orca-tab-view against a fake orca CLI and a fake Orca agent hook.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
H="$here/../hooks"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Fake orca: reachable unless FAKE_ORCA_DOWN; terminal create starts the tab command the
# way Orca would, inside a shell that carries the pane's ORCA_* variables.
mkdir -p "$T/bin" "$T/home/.orca/agent-hooks"
cat > "$T/bin/orca" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/orca.log"
case "\$1 \$2" in
  "status --json") [ -n "\${FAKE_ORCA_DOWN-}" ] && echo '{"result":{"runtime":{"reachable":false}}}' || echo '{"result":{"runtime":{"reachable":true}}}' ;;
  "terminal create")
    while [ \$# -gt 0 ]; do case "\$1" in --command) cmd=\$2 ;; --worktree) wt=\${2#path:} ;; esac; shift; done
    # Like Orca: only registered checkouts are known, never git worktrees made outside Orca.
    grep -qxF "\$wt" "$T/known" || { echo '{"ok":false,"error":{"code":"selector_not_found"}}'; exit 1; }
    ORCA_PANE_KEY=pane-tab ORCA_TAB_ID=tab-1 ORCA_AGENT_HOOK_PORT=1 ORCA_AGENT_HOOK_TOKEN=tok setsid nohup bash -c "\$cmd" > "$T/tab.out" 2>&1 < /dev/null &
    echo '{"result":{"terminal":{"handle":"term_test"}}}' ;;
  *) echo '{"result":{}}' ;;
esac
EOF
cat > "$T/home/.orca/agent-hooks/claude-hook.sh" <<EOF
#!/bin/sh
printf '%s %s\n' "\$ORCA_PANE_KEY" "\$(cat)" >> "$T/forwarded.log"
EOF
chmod +x "$T/bin/orca"
run() {  # run PAYLOAD [VAR=value...]: the hook as Claude Code runs it, from a session inside another Orca pane
  local p=$1; shift
  printf '%s' "$p" | env HOME="$T/home" XDG_STATE_HOME="$T/state" PATH="$T/bin:$PATH" ORCA_PANE_KEY=pane-main \
    SDD_ORCA_TAB_LINGER=0 "$@" bash "$H/run-hook.cmd" orca-tabs
}
calls() { [ -f "$T/orca.log" ] || { echo 0; return; }; grep -c -- "${1:-.}" "$T/orca.log" || true; }

# A session transcript with one workflow agent that works in another checkout.
git init -q "$T/repo"; git init -q "$T/session"; printf '%s\n' "$T/repo" "$T/session" > "$T/known"
sess="$T/proj/sess.jsonl"; adir="$T/proj/sess/subagents/workflows/wf_1"
mkdir -p "$adir"; : > "$sess"
echo '{"agentType":"workflow-subagent","description":"impl:2","model":"opus"}' > "$adir/agent-abc123.meta.json"
jq -nc --arg t "  Work only in the git checkout at $T/repo: start every shell command with cd." \
  '{type:"user",message:{role:"user",content:$t}}' > "$adir/agent-abc123.jsonl"
ev() {  # ev EVENT [extra JSON object]
  local x=${2-}; [ -n "$x" ] || x='{}'
  jq -nc --arg e "$1" --arg tp "$sess" --arg cwd "$T/session" --argjson x "$x" \
    '{hook_event_name:$e, session_id:"parent-session", transcript_path:$tp, cwd:$cwd, agent_id:"abc123", agent_type:"workflow-subagent"} + $x'
}

echo "skips"
out=$(run '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s"}'); rc=$?
check "main-session events exit 0 silently" test "$rc" = 0 -a -z "$out"
run "$(ev SubagentStart '{"agent_type":"general-purpose"}')" >/dev/null
check "ignores non-workflow agents by default" test "$(calls)" = 0
run "$(ev SubagentStart)" SDD_ORCA_TABS=0 >/dev/null
check "SDD_ORCA_TABS=0 turns it off" test "$(calls)" = 0
run "$(ev SubagentStart '{"agent_id":"../x"}')" >/dev/null
check "rejects an unsafe agent id" test "$(calls)" = 0
run "$(ev SubagentStart '{"agent_id":"down1"}')" FAKE_ORCA_DOWN=1 >/dev/null
check "opens no tab when Orca is unreachable" test "$(calls 'terminal create')" = 0
out=$(printf 'not json' | env HOME="$T/home" PATH="$T/bin:$PATH" bash "$H/run-hook.cmd" orca-tabs); rc=$?
check "fails open on bad input" test "$rc" = 0 -a -z "$out"

echo '{"description":"devin:2:impl","model":"haiku"}' > "$adir/agent-drv1.meta.json"
run "$(ev SubagentStart '{"agent_id":"drv1"}')" >/dev/null
check "skips Devin drivers, which have Devin's own tab" test "$(calls 'terminal create')" = 0 -a ! -e "$T/state/sdd-orca/tabs/drv1"

echo "agent lifecycle"
rm -f "$T/orca.log" "$T/state/sdd-orca/tabs/.orca-up"
out=$(run "$(ev SubagentStart)"); rc=$?
check "SubagentStart exits 0 silently" test "$rc" = 0 -a -z "$out"
create=$(grep 'terminal create' "$T/orca.log" || true)
check "opens a tab in the checkout the agent works in" contains "$create" "--worktree path:$T/repo "
check "titles the tab with the workflow label and model" contains "$create" "--title sdd impl:2 · opus"
fw() { grep '^pane-tab ' "$T/forwarded.log" | cut -d' ' -f2- | jq -c "select(.hook_event_name == \"$1\")" | tail -n 1; }
start=$(fw SessionStart)
check "reports SessionStart under the tab's pane" test -n "$start"
check "gives the agent its own session id" test "$(jq -r .session_id <<<"$start")" != parent-session
check "points Orca at the agent's transcript" test "$(jq -r .transcript_path <<<"$start")" = "$adir/agent-abc123.jsonl"
check "reports the label as the prompt" test "$(fw UserPromptSubmit | jq -r .prompt)" = "impl:2"
check "never reports under the session's own pane" test "$(grep -c '^pane-main ' "$T/forwarded.log")" = 0

esc=$(printf '\033')
jq -nc --arg t "editing now ${esc}]0;evil${esc}\\ done" '{type:"assistant",timestamp:"2026-10-13T12:00:01Z",message:{content:[{type:"text",text:$t},{type:"tool_use",name:"Bash",input:{command:"go test ./...",description:"Run the tests"}}]}}' >> "$adir/agent-abc123.jsonl"
run "$(ev PreToolUse '{"tool_name":"Bash","tool_input":{"command":"go test ./..."}}')" >/dev/null
pre=$(fw PreToolUse)
check "forwards tool events" test "$(jq -r .tool_name <<<"$pre")" = Bash
check "strips the subagent fields" test "$(jq -c '[has("agent_id"), has("agent_type")]' <<<"$pre")" = '[false,false]'
check "keeps one session id per agent" test "$(jq -r .session_id <<<"$pre")" = "$(jq -r .session_id <<<"$start")"

run "$(ev SubagentStop '{"last_assistant_message":"All done.\nSTATUS: DONE tests pass","agent_transcript_path":"'"$adir/agent-abc123.jsonl"'"}')" >/dev/null
check "reports Stop with the last message" contains "$(fw Stop | jq -r .last_assistant_message)" "STATUS: DONE"
check "marks the tab finished" contains "$(grep 'terminal rename' "$T/orca.log" || true)" "sdd impl:2 · opus ✓"
for _ in $(seq 1 50); do [ -d "$T/state/sdd-orca/tabs/abc123" ] || break; sleep 0.2; done
tab=$(cat "$T/tab.out" 2>/dev/null)
check "the tab shows the task" contains "$tab" "Work only in the git checkout"
check "the tab shows tool calls" contains "$tab" "Bash: Run the tests"
check "the tab strips escapes from the transcript" test "$(grep -c "${esc}]0;evil" "$T/tab.out")" = 0 -a "$(grep -c "]0;evil" "$T/tab.out")" = 1
check "the tab sets its own title" contains "$tab" "${esc}]0;sdd impl:2 · opus"
check "the tab shows the outcome" contains "$tab" "STATUS: DONE tests pass"
check "the tab removes its state, pane identity included" test ! -e "$T/state/sdd-orca/tabs/abc123"
n=$(wc -l < "$T/forwarded.log")
run "$(ev PostToolUse '{"tool_name":"Bash"}')" >/dev/null
check "drops events after the agent stopped" test "$(wc -l < "$T/forwarded.log")" = "$n"

echo "worktree Orca does not manage"
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/repo" worktree add -q "$T/wt" -b wt-probe
echo '{"description":"impl:3","model":"opus"}' > "$adir/agent-wt1.meta.json"
jq -nc --arg t "  Work only in the git checkout at $T/wt: start every shell command with cd." \
  '{type:"user",message:{role:"user",content:$t}}' > "$adir/agent-wt1.jsonl"
rm -f "$T/orca.log"
run "$(ev SubagentStart '{"agent_id":"wt1"}')" >/dev/null
check "tries the agent's worktree first" grep -q -- "terminal create --worktree path:$T/wt " "$T/orca.log"
check "then opens the tab under the main checkout" grep -q -- "terminal create --worktree path:$T/repo " "$T/orca.log"
check "the tab is set up" test -e "$T/state/sdd-orca/tabs/wt1/ready"
run "$(ev SubagentStop '{"agent_id":"wt1","last_assistant_message":"STATUS: DONE"}')" >/dev/null
for _ in $(seq 1 50); do [ -d "$T/state/sdd-orca/tabs/wt1" ] || break; sleep 0.2; done
check "and closes it when the agent stops" test ! -e "$T/state/sdd-orca/tabs/wt1"
finish
