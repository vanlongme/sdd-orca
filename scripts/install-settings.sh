#!/usr/bin/env bash
# Merge settings/recommended.json into your Claude Code user settings, and install the
# context-hygiene rules from settings/CLAUDE.md into the CLAUDE.md next to it.
#
#   bash scripts/install-settings.sh [--dry-run] [--with-devin] [--no-claude-md] [--target FILE]
#
# Keys in recommended.json replace the same keys in the target; every other key is kept.
# The rules go between <!-- sdd-orca:begin --> and <!-- sdd-orca:end --> markers in
# <target dir>/CLAUDE.md: appended the first time, replaced in place afterwards, and the
# rest of the file is kept. Each file is backed up to <file>.bak-sdd-orca-<timestamp>
# before it is changed. --dry-run prints what would change and writes nothing.
# --no-claude-md leaves CLAUDE.md alone.
# --with-devin also adds the allow rule Bash(sdd-devin:*). That rule lets ANY agent in your
#   sessions start Devin with its permission checks bypassed, without asking you, including
#   an agent steered by text in a repository, plan or issue. Add it only on machines and
#   repositories you trust. It is unioned into permissions.allow, never replacing the list.
set -euo pipefail

die() { echo "install-settings: $*" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/settings/recommended.json"
md_src="$root/settings/CLAUDE.md"
target="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
dry=0 devin=false claude_md=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --with-devin) devin=true ;;
    --no-claude-md) claude_md=0 ;;
    --target) [ $# -ge 2 ] || die "--target needs a file"; target=$2; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || die "jq is required"
[ -f "$src" ] || die "missing $src"

current='{}'
if [ -f "$target" ]; then current=$(jq -e 'if type == "object" then . else error("not an object") end' "$target") || die "$target is not a JSON object"; fi

# recommended.json never grants permissions; the only rule this script can add is the
# explicit --with-devin one.
merged=$(jq -n --argjson cur "$current" --slurpfile rec "$src" --argjson devin "$devin" '
  ($rec[0] | del(.permissions)) as $r
  | ($cur * $r)
  | if $devin then
      ($cur.permissions.allow // []) as $a
      | .permissions.allow = ($a + (["Bash(sdd-devin:*)"] - $a))
    else . end')

# Work out the new CLAUDE.md before writing anything, so a malformed file stops the run.
B='<!-- sdd-orca:begin -->' E='<!-- sdd-orca:end -->'
md="$(dirname "$target")/CLAUDE.md"
new_md=''
if [ "$claude_md" = 1 ]; then
  [ -f "$md_src" ] || die "missing $md_src"
  if [ -f "$md" ]; then
    nb=$(grep -cxF "$B" "$md" || true); ne=$(grep -cxF "$E" "$md" || true)
    { [ "$nb" = "$ne" ] && [ "$nb" -le 1 ]; } || die "$md has unbalanced or repeated sdd-orca markers; fix them by hand"
    if [ "$nb" = 1 ]; then
      lb=$(grep -nxF "$B" "$md" | cut -d: -f1); le=$(grep -nxF "$E" "$md" | cut -d: -f1)
      [ "$lb" -lt "$le" ] || die "$md has its sdd-orca end marker before the begin marker; fix it by hand"
      new_md=$(awk -v src="$md_src" -v b="$B" -v e="$E" '
        $0 == b { while ((getline line < src) > 0) print line; skip = 1; next }
        skip && $0 == e { skip = 0; next }
        !skip { print }' "$md")
    elif [ -s "$md" ]; then
      new_md="$(cat "$md")"$'\n\n'"$(cat "$md_src")"
    else
      new_md=$(cat "$md_src")
    fi
  else
    new_md=$(cat "$md_src")
  fi
fi

backup() {  # never overwrites an earlier backup
  local f=$1 base b n=0
  base="$f.bak-sdd-orca-$(date +%Y%m%d%H%M%S)"; b=$base
  while [ -e "$b" ]; do n=$((n + 1)); b="$base-$n"; done
  cp -p "$f" "$b"
  echo "backup: $b"
}
write() {  # write FILE CONTENT atomically
  local tmp; tmp=$(mktemp "$1.XXXXXX")
  printf '%s\n' "$2" > "$tmp"
  mv "$tmp" "$1"
}

if [ "$dry" = 1 ]; then
  printf '%s\n' "$merged"
  if [ "$claude_md" = 1 ]; then
    if [ -f "$md" ] && [ "$(cat "$md")" = "$new_md" ]; then echo "--- $md: unchanged"
    else echo "--- $md: the sdd-orca rules block would be $([ -f "$md" ] && grep -qxF "$B" "$md" && echo replaced || echo added)"; fi
  fi
  exit 0
fi

mkdir -p "$(dirname "$target")"
[ -f "$target" ] && backup "$target"
write "$target" "$merged"
echo "updated: $target"
if [ "$devin" = true ]; then
  echo "added Bash(sdd-devin:*): agents can now start Devin without asking you. Remove the rule when you stop running Devin plans."
fi
if [ "$claude_md" = 1 ]; then
  if [ -f "$md" ] && [ "$(cat "$md")" = "$new_md" ]; then
    echo "unchanged: $md"
  else
    [ -f "$md" ] && backup "$md"
    write "$md" "$new_md"
    echo "updated: $md"
  fi
fi
