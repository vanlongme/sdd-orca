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
check "caps inline Bash output and sets cache TTLs" test "$(jq -c '[.bashOutputMaxChars, .promptCacheTtl, .subagentPromptCacheTtl]' <<<"$out")" = '[12000,"1h","5m"]'
check "does not add the Devin rule by default" test "$(jq -c .permissions.allow <<<"$out")" = '["Bash(ls:*)"]'
check "keeps the deny list" test "$(jq -c .permissions.deny <<<"$out")" = '["Bash(rm:*)"]'
out=$(bash "$I" --target "$tmp/s.json" --dry-run --with-devin)
check "--with-devin unions the Devin rule in order" test "$(jq -c .permissions.allow <<<"$out")" = '["Bash(ls:*)","Bash(sdd-devin:*)"]'
out=$(bash "$I" --target "$tmp/none.json" --dry-run)
check "a missing target starts from an empty object" test "$(jq -c 'has("permissions")' <<<"$out")" = false
out=$(bash "$I" --target "$tmp/none.json" --dry-run --with-devin)
check "--with-devin works without an existing allow list" test "$(jq -c .permissions.allow <<<"$out")" = '["Bash(sdd-devin:*)"]'

bash "$I" --target "$tmp/s.json" --with-devin >/dev/null
check "writes a backup of the original" cmp -s "$tmp/orig.json" "$(ls "$tmp"/s.json.bak-sdd-orca-* | head -1)"
bash "$I" --target "$tmp/s.json" --with-devin >/dev/null
check "is idempotent" test "$(jq -c .permissions.allow "$tmp/s.json")" = '["Bash(ls:*)","Bash(sdd-devin:*)"]'
echo '[1]' > "$tmp/bad.json"
check "refuses a non-object target" test "$(bash "$I" --target "$tmp/bad.json" >/dev/null 2>&1; echo $?)" = 2
check "the non-object target is untouched" test "$(cat "$tmp/bad.json")" = '[1]'
check "rejects unknown options" test "$(bash "$I" --force >/dev/null 2>&1; echo $?)" = 2
check "the recommended file grants no permissions" test "$(jq -c 'has("permissions")' "$here/../settings/recommended.json")" = false

echo "CLAUDE.md rules"
B='<!-- sdd-orca:begin -->' E='<!-- sdd-orca:end -->'
d="$tmp/md"; mkdir -p "$d"; echo '{}' > "$d/settings.json"
bash "$I" --target "$d/settings.json" --dry-run >/dev/null
check "dry-run writes no CLAUDE.md" test ! -e "$d/CLAUDE.md"
bash "$I" --target "$d/settings.json" >/dev/null
check "creates CLAUDE.md next to the settings file" test -f "$d/CLAUDE.md"
check "the block is delimited by markers" test "$(grep -cxF "$B" "$d/CLAUDE.md")$(grep -cxF "$E" "$d/CLAUDE.md")" = 11
check "the block carries the no-polling rule" grep -qi "poll" "$d/CLAUDE.md"
check "the block recommends run_in_background plus the completion notification" grep -q "run_in_background" "$d/CLAUDE.md"
check "the block recommends Monitor with an until condition instead of sleep" bash -c 'grep -q "Monitor" "$1" && grep -q "until " "$1"' _ "$d/CLAUDE.md"
check "the block asks watches to cover failure states" grep -qi "fail" "$d/CLAUDE.md"
check "the block carries the long-output rule" grep -q "bashOutputMaxChars\|long output\|Command output" "$d/CLAUDE.md"
check "the block matches settings/CLAUDE.md" bash -c 'diff <(sed -n "/^<!-- sdd-orca:begin -->$/,/^<!-- sdd-orca:end -->$/p" "$1") "$2" >/dev/null' _ "$d/CLAUDE.md" "$here/../settings/CLAUDE.md"

printf '# My rules\n\nKeep answers short.\n' > "$d/CLAUDE.md"; cp "$d/CLAUDE.md" "$d/mine.md"
bash "$I" --target "$d/settings.json" >/dev/null
check "keeps the user's own CLAUDE.md text first" test "$(head -n 3 "$d/CLAUDE.md")" = "$(cat "$d/mine.md")"
check "backs up an existing CLAUDE.md" cmp -s "$d/mine.md" "$(ls "$d"/CLAUDE.md.bak-sdd-orca-* | head -1)"
bash "$I" --target "$d/settings.json" >/dev/null
bash "$I" --target "$d/settings.json" >/dev/null
check "backups made within the same second never overwrite each other" test "$(ls "$d"/settings.json.bak-sdd-orca-* | wc -l)" -ge 3
check "reinstalling keeps exactly one block" test "$(grep -cxF "$B" "$d/CLAUDE.md")" = 1
printf '%s\n' "# My rules" "" "Keep answers short." "" "$B" "old rule text" "$E" "" "Trailing note." > "$d/CLAUDE.md"
bash "$I" --target "$d/settings.json" >/dev/null
check "an old block is replaced in place" test "$(grep -c 'old rule text' "$d/CLAUDE.md")" = 0 -a "$(tail -n 1 "$d/CLAUDE.md")" = "Trailing note."
check "text around the block is kept" test "$(head -n 3 "$d/CLAUDE.md" | tail -n 1)" = "Keep answers short."
printf '%s\n' "mine" "$B" "unterminated" > "$d/CLAUDE.md"; cp "$d/CLAUDE.md" "$d/broken.md"; echo '{}' > "$d/settings.json"
check "an unterminated block is refused" test "$(bash "$I" --target "$d/settings.json" >/dev/null 2>&1; echo $?)" = 2
check "the refused CLAUDE.md is untouched" cmp -s "$d/CLAUDE.md" "$d/broken.md"
check "a refused run does not write the settings either" test "$(jq -c . "$d/settings.json")" = '{}'
rm "$d/CLAUDE.md"
bash "$I" --target "$d/settings.json" --no-claude-md >/dev/null
check "--no-claude-md leaves CLAUDE.md alone" test ! -e "$d/CLAUDE.md"

finish
