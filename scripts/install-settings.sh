#!/usr/bin/env bash
# Merge settings/recommended.json into your Claude Code user settings.
#
#   bash scripts/install-settings.sh [--dry-run] [--with-devin] [--target FILE]
#
# Keys in recommended.json replace the same keys in the target; every other key is kept.
# The target is backed up to <target>.bak-sdd-orca-<timestamp> before it is written.
# --dry-run prints the merged file and changes nothing.
# --with-devin also adds the allow rule Bash(sdd-devin:*). That rule lets ANY agent in your
#   sessions start Devin with its permission checks bypassed, without asking you, including
#   an agent steered by text in a repository, plan or issue. Add it only on machines and
#   repositories you trust. It is unioned into permissions.allow, never replacing the list.
set -euo pipefail

die() { echo "install-settings: $*" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/settings/recommended.json"
target="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
dry=0 devin=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --with-devin) devin=true ;;
    --target) [ $# -ge 2 ] || die "--target needs a file"; target=$2; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
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

if [ "$dry" = 1 ]; then
  printf '%s\n' "$merged"
  exit 0
fi
mkdir -p "$(dirname "$target")"
if [ -f "$target" ]; then
  backup="$target.bak-sdd-orca-$(date +%Y%m%d%H%M%S)"
  cp -p "$target" "$backup"
  echo "backup: $backup"
fi
tmp=$(mktemp "$target.XXXXXX")
printf '%s\n' "$merged" > "$tmp"
mv "$tmp" "$target"
echo "updated: $target"
if [ "$devin" = true ]; then
  echo "added Bash(sdd-devin:*): agents can now start Devin without asking you. Remove the rule when you stop running Devin plans."
fi
