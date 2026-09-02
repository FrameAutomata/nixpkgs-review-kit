#!/usr/bin/env bash
# Explain build failures from nixpkgs-review reports. For every failed package it
# says whether a report already marks it "still failing on base", what Hydra's
# latest build of it on the base branch looks like, and whether nixpkgs has an
# open issue about it.
#
# Usage: scripts/triage-failures.sh PR          # gather every report for the PR:
#                                               #   the update bot's report in the PR body,
#                                               #   ~/.cache/nixpkgs-review/pr-PR/report.md,
#                                               #   and the fork's newest successful run,
#                                               #   which is saved to reports/PR-gha.md
#        scripts/triage-failures.sh REPORT.md   # parse one report file (assumes base = master)
#
# Verdict hints are exactly that: hints. Say in the review what you checked.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
all="$tmp/all.tsv"; : > "$all"
pr_base=master; pr_base_sha=""

case "${1:-}" in '' | -h | --help) usage; exit 2 ;; esac
if [[ -f "$1" ]]; then
  extract_failures "$1" "$(basename "$1")" >> "$all"
elif [[ "$1" =~ ^[0-9]+$ ]]; then
  pr=$1
  pr_meta "$pr" "$tmp/body.md" || die "cannot read PR #$pr"
  extract_failures "$tmp/body.md" update-bot >> "$all"
  f="$HOME/.cache/nixpkgs-review/pr-$pr/report.md"
  [[ -f "$f" ]] && extract_failures "$f" local >> "$all"
  f="$KIT/reports/$pr-gha.md"
  run=$(gha_report "$pr" "$f")
  [[ -f "$f" ]] && extract_failures "$f" "gha${run:+-run-$run}" >> "$all"
else
  usage; exit 2
fi

if [[ ! -s "$all" ]]; then echo "no failures found in the available reports"; exit 0; fi

# hydra_query ATTR SYSTEM -> latestbuilds query for the base branch, or nothing when
# Hydra does not build that branch. Release branches keep Linux under the nixos
# project (job "nixpkgs.ATTR.SYSTEM") and darwin under nixpkgs/nixpkgs-VERSION-darwin.
hydra_query() {
  case "$pr_base" in
    master)       echo "project=nixpkgs&jobset=unstable&job=$1.$2" ;;
    staging-next) echo "project=nixpkgs&jobset=staging-next&job=$1.$2" ;;
    release-*)    local v=${pr_base#release-}
                  case "$2" in
                    *-darwin) echo "project=nixpkgs&jobset=nixpkgs-$v-darwin&job=$1.$2" ;;
                    *)        echo "project=nixos&jobset=release-$v&job=nixpkgs.$1.$2" ;;
                  esac ;;
  esac
}

# hydra ATTR SYSTEM -> one line: flag<TAB>message, flag being ok | stale | failing | none.
# Uses the latestbuilds API: the per-job "latest" page only ever shows successful builds.
hydra() {
  local q j st ts d age
  q=$(hydra_query "$1" "$2")
  if [[ -z "$q" ]]; then printf 'none\t%s\n' "Hydra: skipped, Hydra does not build base branch $pr_base"; return; fi
  j=$(curl -sf -m 20 -H 'Accept: application/json' "https://hydra.nixos.org/api/latestbuilds?nr=1&$q" 2>/dev/null) || j=""
  st=$(grep -oE '"buildstatus":[0-9]+' <<<"$j" | head -1 | cut -d: -f2 || true)
  ts=$(grep -oE '"timestamp":[0-9]+' <<<"$j" | head -1 | cut -d: -f2 || true)
  if [[ -z "$j" ]]; then printf 'none\t%s\n' "Hydra: lookup failed"; return; fi
  if [[ -z "$st" || -z "$ts" ]]; then printf 'none\t%s\n' "Hydra: no finished build (Hydra does not build $1 on $2)"; return; fi
  d=$(date -u -d "@$ts" +%Y-%m-%d); age=$(( (EPOCHSECONDS - ts) / 86400 ))
  if [[ "$st" != 0 ]]; then
    printf 'failing\t%s\n' "Hydra: FAILING on $pr_base, latest build $d (status $st)"
  elif (( age > 60 )); then
    printf 'stale\t%s\n' "Hydra: last build succeeded $d, $age days ago; stale, Hydra may have stopped building it"
  else
    printf 'ok\t%s\n' "Hydra: OK on $pr_base, built $d"
  fi
}

# issues ATTR -> lines "#N title" for open issues with ATTR in the title that look like build failures.
issues() {
  gh search issues "\"$1\"" --repo "$NIXPKGS_REPO" --state open --match title --limit 10 \
    --json number,title \
    --jq '.[] | select(.title | test("fail|broken|error|build"; "i")) | "#\(.number) \(.title)"' 2>/dev/null || true
}

# One row per (system, attr): system<TAB>attr<TAB>"label:kind label:kind ...".
mapfile -t rows < <(awk -F'\t' '
  { k = $2 FS $4; kinds[k] = kinds[k] " " $1 ":" $3 }
  END { for (k in kinds) print k FS substr(kinds[k], 2) }' "$all" | sort)

# Lookups only where the reports alone do not settle it: plain failures that are
# not already marked still-failing. Hydra queries run in parallel (bounded);
# GitHub issue searches are rate-limited, so they run one at a time, once per attr.
needs_lookup() { [[ $1 == *:failed* && $1 != *still-failing* ]]; }
key() { echo "$1.${2//\//_}"; }

for row in "${rows[@]}"; do
  IFS=$'\t' read -r sys attr kinds <<<"$row"
  needs_lookup "$kinds" || continue
  hydra "$attr" "$sys" > "$tmp/hydra.$(key "$sys" "$attr")" &
  (( $(jobs -rp | wc -l) < 8 )) || wait -n
done
declare -A searched=()
for row in "${rows[@]}"; do
  IFS=$'\t' read -r sys attr kinds <<<"$row"
  needs_lookup "$kinds" || continue
  [[ -v searched[$attr] ]] && continue
  searched[$attr]=1
  issues "$attr" > "$tmp/issues.${attr//\//_}"
done
wait

echo "reports consulted: $(cut -f1 "$all" | sort -u | paste -sd, -)"
echo
for row in "${rows[@]}"; do
  IFS=$'\t' read -r sys attr kinds <<<"$row"
  echo "== $attr on $sys"
  echo "   reported: $kinds"

  hflag=none; iss=""
  if needs_lookup "$kinds"; then
    IFS=$'\t' read -r hflag hmsg < "$tmp/hydra.$(key "$sys" "$attr")" || { hflag=none; hmsg="Hydra: lookup failed"; }
    iss=$(<"$tmp/issues.${attr//\//_}")
    echo "   $hmsg"
    [[ -n "$iss" ]] && sed 's/^/   open issue: /' <<<"$iss"
  fi

  if [[ $kinds == *:crashed* ]]; then
    v="the update bot's own nixpkgs-review run crashed; open its log link in the PR body (an eval error introduced by the PR shows up this way)"
  elif [[ $kinds == *still-failing* ]]; then
    v="pre-existing: also fails on the base branch"
  elif [[ $kinds != *:failed* ]]; then
    v="runner limitation (missing system feature), not a PR problem"
  elif [[ $hflag == failing ]]; then
    v="pre-existing: Hydra's latest build on $pr_base fails too"
  elif [[ $hflag == stale ]]; then
    v="probably pre-existing: Hydra stopped building it; confirm with a base build"
  elif [[ ${iss,,} == *"build failure"* ]]; then
    v="likely pre-existing: open build-failure issue"
  elif [[ $hflag == ok ]]; then
    v="NEEDS A LOOK: Hydra builds it on $pr_base, so this is either the PR or the runner environment (a cached base rebuild in Actions proves nothing)"
  else
    v="unknown, check the log"
  fi
  echo "   verdict hint: $v"
  if [[ -n "$pr_base_sha" && $kinds != *:crashed* ]]; then
    case "$sys" in
      *-linux)  echo "   confirm on base: nix-build https://github.com/NixOS/nixpkgs/archive/$pr_base_sha.tar.gz -A $attr" ;;
      *-darwin) echo "   confirm on base: rerun in Actions; still-failing detection rebuilds it on the base branch" ;;
    esac
  fi
  echo
done
