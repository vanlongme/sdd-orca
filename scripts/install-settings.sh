#!/usr/bin/env bash
# Merge settings/recommended.json into your Claude Code user settings.
#
#   bash scripts/install-settings.sh [--dry-run] [--no-devin] [--target FILE]
#
# Keys in recommended.json replace the same keys in the target; every other key is kept.
# permissions.allow is unioned, never replaced. The target is backed up to
# <target>.bak-sdd-orca-<timestamp> before it is written. --dry-run prints the merged
# file and changes nothing. --no-devin leaves out the Bash(sdd-devin:*) allow rule.
set -euo pipefail

die() { echo "install-settings: $*" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/settings/recommended.json"
target="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
dry=0 no_devin=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --no-devin) no_devin=true ;;
    --target) [ $# -ge 2 ] || die "--target needs a file"; target=$2; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || die "jq is required"
[ -f "$src" ] || die "missing $src"

current='{}'
if [ -f "$target" ]; then current=$(jq -e 'if type == "object" then . else error("not an object") end' "$target") || die "$target is not a JSON object"; fi

merged=$(jq -n --argjson cur "$current" --slurpfile rec "$src" --argjson nodevin "$no_devin" '
  ($rec[0] | if $nodevin then .permissions.allow -= ["Bash(sdd-devin:*)"] else . end) as $r
  | ($cur.permissions.allow // []) as $a
  | ($cur * $r)
  | .permissions.allow = ($a + (($r.permissions.allow // []) - $a))
  | if (.permissions.allow | length) == 0 then del(.permissions.allow) else . end
  | if (.permissions // {}) == {} then del(.permissions) else . end')

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
