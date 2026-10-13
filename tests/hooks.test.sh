#!/usr/bin/env bash
# Tests the plugin hooks: the superpowers SDD redirect and the SessionStart context.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
H="$here/../hooks"
skill() { printf '{"tool_name":"Skill","tool_input":{"skill":"%s"}}' "$1"; }

echo "redirect-sdd"
out=$(skill superpowers:subagent-driven-development | env -u SDD_MANUAL bash "$H/run-hook.cmd" redirect-sdd); rc=$?
check "exits 0 when denying" test "$rc" = 0
check "denies superpowers SDD" test "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" = deny
check "names the PreToolUse event" test "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")" = PreToolUse
check "redirects to the sdd-orca skill" contains "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" '"sdd-orca:subagent-driven-development"'
for s in sdd-orca:subagent-driven-development subagent-driven-development superpowers:writing-plans; do
  out=$(skill "$s" | bash "$H/run-hook.cmd" redirect-sdd)
  check "leaves $s alone" test -z "$out"
done
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"superpowers:subagent-driven-development"}}' | bash "$H/run-hook.cmd" redirect-sdd)
check "ignores other tools" test -z "$out"
out=$(skill superpowers:subagent-driven-development | SDD_MANUAL=1 bash "$H/run-hook.cmd" redirect-sdd)
check "SDD_MANUAL=1 disables the redirect" test -z "$out"
out=$(printf 'not json' | bash "$H/run-hook.cmd" redirect-sdd); rc=$?
check "fails open on bad input" test "$rc" = 0 -a -z "$out"
out=$(skill superpowers:subagent-driven-development | PATH=/nonexistent /bin/bash "$H/redirect-sdd" 2>/dev/null); rc=$?
check "fails open without jq" test "$rc" = 0 -a -z "$out"

echo "session-start"
out=$(CLAUDE_PLUGIN_ROOT="$here/.." bash "$H/run-hook.cmd" session-start)
valid() { jq -e . >/dev/null 2>&1; }
check "emits valid JSON" valid <<<"$out"
ctx=$(jq -r .hookSpecificOutput.additionalContext <<<"$out")
check "injects the using-superpowers skill" contains "$ctx" "name: using-superpowers"
check "uses the sdd-orca namespace" contains "$ctx" "sdd-orca:using-superpowers"

echo "hooks.json"
check "is valid JSON" valid < "$H/hooks.json"
check "registers the Skill matcher" test "$(jq -r '.hooks.PreToolUse[0].matcher' "$H/hooks.json")" = Skill
check "hook scripts are executable" test -x "$H/redirect-sdd" -a -x "$H/session-start" -a -x "$H/run-hook.cmd" -a -x "$H/orca-tabs" -a -x "$H/orca-tab-view"
for e in SubagentStart SubagentStop PreToolUse PostToolUse PostToolUseFailure PermissionRequest; do
  check "runs orca-tabs async on $e" test "$(jq -r --arg e "$e" '[.hooks[$e][].hooks[] | select(.command | endswith(" orca-tabs")) | .async] | . == [true]' "$H/hooks.json")" = true
done

finish
