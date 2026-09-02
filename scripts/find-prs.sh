#!/usr/bin/env bash
# List open nixpkgs PRs that are good candidates for a quick, useful review.
#
# Usage: scripts/find-prs.sh [options] [LIMIT] [EXTRA GITHUB SEARCH TERMS...]
#   --tier 1|1-10|11-100   rebuild-count label to require (default: 1, leaf packages, fastest runs)
#   --any                  drop the "9.needs: reviewer" filter (include PRs someone is already on)
#
# Columns: number, age, author, update-bot verdict, title.
#   bot:ok    the PR body carries the update bot's nixpkgs-review result and everything built
#   bot:FAIL  that report lists failures on x86_64-linux (read it before building anything)
#   -         no bot report in the body (human-authored PR)
#
# Examples:
#   scripts/find-prs.sh                       # 10 newest leaf package updates nobody is reviewing
#   scripts/find-prs.sh --tier 1-10 20        # widen to up to 10 rebuilds
#   scripts/find-prs.sh 10 author:r-ryantm    # bot bumps only
#   scripts/find-prs.sh 10 "python3Packages"  # text search in title/body
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

tier=1; needs_reviewer=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier) tier="${2:?--tier needs a value}"; shift ;;
    --any) needs_reviewer=false ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage; exit 2 ;;
    *) break ;;
  esac
  shift
done
limit="${1:-10}"
extra="${*:2}"

search="label:\"10.rebuild-linux: $tier\" label:\"8.has: package (update)\""
search+=' -label:"2.status: merge conflict" -label:"2.status: work-in-progress"'
search+=' review:none draft:false sort:created-desc'
$needs_reviewer && search+=' label:"9.needs: reviewer"'
[[ -n "$extra" ]] && search+=" $extra"

gh pr list -R "$NIXPKGS_REPO" --state open --limit "$limit" --search "$search" \
  --json number,title,createdAt,author,body \
  --jq '.[] | ((now - (.createdAt | fromdateiso8601)) / 60 | floor) as $m
        | [ .number,
            (if $m < 60 then "\($m)m" elif $m < 1440 then "\($m / 60 | floor)h" else "\($m / 1440 | floor)d" end),
            (.author.login // "-"),
            '"$BOT_REPORT_JQ"',
            .title ] | join("\u001f")' \
| while IFS=$US read -r num age author bot title; do
    printf '#%-7s %-5s %-16s %-9s %s\n' "$num" "$age" "$author" "$bot" "$title"
  done
