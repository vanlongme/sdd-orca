#!/usr/bin/env bash
# Tests scripts/install-settings.sh against throwaway settings files.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
I="$here/../scripts/install-settings.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo '{"model":"opus","env":{"KEEP":"1","CLAUDE_CODE_SUBAGENT_MODEL":"haiku"},"permissions":{"allow":["Bash(ls:*)"],"deny":["Bash(rm:*)"]},"hooks":{"Stop":[]}}' > "$tmp/s.json"
cp "$tmp/s.json" "$tmp/orig.json"
out=$(bash "$I" --target "$tmp/s.json" --dry-run)
check "dry-run leaves the file unchanged" cmp -s "$tmp/s.json" "$tmp/orig.json"
check "dry-run writes no backup" test -z "$(ls "$tmp" | grep bak)"
check "keeps unrelated keys" test "$(jq -c '[.model, .env.KEEP, .hooks]' <<<"$out")" = '["opus","1",{"Stop":[]}]'
check "recommended values win" test "$(jq -r .env.CLAUDE_CODE_SUBAGENT_MODEL <<<"$out")" = sonnet
check "adds compaction and workflow keys" test "$(jq -c '[.autoCompactWindow, .workflowSizeGuideline]' <<<"$out")" = '[400000,"medium"]'
check "unions the allow list in order" test "$(jq -c .permissions.allow <<<"$out")" = '["Bash(ls:*)","Bash(sdd-devin:*)"]'
check "keeps the deny list" test "$(jq -c .permissions.deny <<<"$out")" = '["Bash(rm:*)"]'
out=$(bash "$I" --target "$tmp/s.json" --dry-run --no-devin)
check "--no-devin leaves out the Devin rule" test "$(jq -c .permissions.allow <<<"$out")" = '["Bash(ls:*)"]'
out=$(bash "$I" --target "$tmp/none.json" --dry-run --no-devin)
check "a missing target starts from an empty object" test "$(jq -c 'has("permissions")' <<<"$out")" = false

bash "$I" --target "$tmp/s.json" >/dev/null
check "writes a backup of the original" cmp -s "$tmp/orig.json" "$(ls "$tmp"/s.json.bak-sdd-orca-* | head -1)"
bash "$I" --target "$tmp/s.json" >/dev/null
check "is idempotent" test "$(jq -c .permissions.allow "$tmp/s.json")" = '["Bash(ls:*)","Bash(sdd-devin:*)"]'
echo '[1]' > "$tmp/bad.json"
check "refuses a non-object target" test "$(bash "$I" --target "$tmp/bad.json" >/dev/null 2>&1; echo $?)" = 2
check "the non-object target is untouched" test "$(cat "$tmp/bad.json")" = '[1]'
check "rejects unknown options" test "$(bash "$I" --force >/dev/null 2>&1; echo $?)" = 2

finish
