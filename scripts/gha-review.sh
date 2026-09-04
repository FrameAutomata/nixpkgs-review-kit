#!/usr/bin/env bash
# Trigger nixpkgs-review-gha in your fork for one or more nixpkgs PRs, after a pre-flight check.
#
# Usage: scripts/gha-review.sh [options] PR [PR...]
#   --darwin        also build on aarch64-darwin and x86_64-darwin (default: Linux only)
#   --post          post the report to the PR (default: do NOT post)
#   --force         dispatch even when pre-flight says skip
#   --extra-args S  extra nixpkgs-review args, e.g. "--package foo" or "--skip-package bar"
#   --watch         follow the run that was just started (single PR only)
#   --dry-run       run pre-flight and print the gh command instead of dispatching
#
# Pre-flight, per PR: skips PRs that are not open, drafts, already approved,
# in merge conflict, or labelled with more than 100 rebuilds (too big for
# hosted runners). It also prints the rebuild labels and whether the update
# bot's own build report in the PR body lists failures, so you can read that
# before building.
#
# The fork is FrameAutomata/nixpkgs-review-gha unless NRGHA_REPO is set.
# on-success is always "nothing": approving or merging stays a human action.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

darwin=false; post=false; force=false; watch=false; dry=false; extra=""
prs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --darwin) darwin=true ;;
    --post) post=true ;;
    --force) force=true ;;
    --extra-args) extra="${2:?--extra-args needs a value}"; shift ;;
    --watch) watch=true ;;
    --dry-run) dry=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage; exit 2 ;;
    *) [[ $1 =~ ^[0-9]+$ ]] || die "PR must be a number, got: $1"; prs+=("$1") ;;
  esac
  shift
done

[[ ${#prs[@]} -gt 0 ]] || { usage; exit 2; }
if $watch && [[ ${#prs[@]} -gt 1 ]]; then
  die "--watch only works with a single PR"
fi

# Prints a short summary; returns 0 to dispatch, 1 to skip.
preflight() {
  local pr=$1
  pr_meta "$pr" /dev/null || { echo "  #$pr: cannot read PR"; return 1; }
  echo "  #$pr $pr_title"
  echo "     base $pr_base | rebuilds: ${pr_rebuilds:-none} | bot report on x86_64-linux: $pr_bot | approvals: $pr_approvals"

  # Lower bound of the Linux rebuild tier: "1-10" -> 1, "11-100" -> 11, "501+" -> 501.
  local n=0 nd=0 skip=""
  [[ $pr_rebuilds =~ linux:\ ([0-9]+) ]] && n=${BASH_REMATCH[1]}
  [[ $pr_rebuilds =~ darwin:\ ([0-9]+) ]] && nd=${BASH_REMATCH[1]}
  if [[ $pr_state != OPEN ]]; then skip="PR is $pr_state"
  elif [[ $pr_draft == true ]]; then skip="draft"
  elif [[ $pr_decision == APPROVED || $pr_approvals != 0 || $pr_labels == *"12.approvals:"* ]]; then skip="already approved"
  elif [[ $pr_labels == *"2.status: merge conflict"* ]]; then skip="merge conflict"
  elif (( n > 100 )) || [[ $pr_rebuilds == *linux-stdenv* ]]; then skip="too many rebuilds for hosted runners"
  elif $darwin && (( nd > 100 )); then skip="too many darwin rebuilds for the macOS runners"
  fi
  if [[ -n "$skip" ]]; then
    if $force; then echo "     pre-flight: $skip (forced)"; return 0; fi
    echo "     pre-flight: SKIP, $skip (use --force to override)"; return 1
  fi
  [[ $pr_bot == bot:FAIL ]] && echo "     note: the bot's report lists failures; scripts/triage-failures.sh $pr explains them before you build"
  (( n >= 11 )) && echo "     note: $n+ rebuilds, expect a long run"
  return 0
}

echo "pre-flight:"
go=()
for pr in "${prs[@]}"; do
  preflight "$pr" && go+=("$pr")
done
[[ ${#go[@]} -gt 0 ]] || { echo "nothing to dispatch"; exit 0; }

systems=linux; $darwin && systems=linux+darwin
# Remember the newest existing run for the watched PR so the new one can be told apart.
before=""
# --watch polls for a run that does not exist yet; a cached listing would never
# show it, so this whole script bypasses the cache.
export RUNS_CACHE_TTL=0
if $watch && ! $dry; then before=$(run_for_pr "${go[0]}" || true); fi

echo "dispatch:"
for pr in "${go[@]}"; do
  args=(workflow run review.yml -R "$REPO"
        -f "pr=$pr"
        -f "post-result=$post"
        -f "on-success=nothing")
  $darwin || args+=(-f "x86_64-darwin=no" -f "aarch64-darwin=no")
  [[ -n "$extra" ]] && args+=(-f "extra-args=$extra")

  if $dry; then
    printf '  gh'; printf ' %q' "${args[@]}"; printf '\n'
    continue
  fi
  gh "${args[@]}" >/dev/null \
    || die "dispatch failed. Does the fork $REPO exist with workflows enabled? See README.md, 'One-time setup'."
  echo "  #$pr started on $REPO (systems: $systems, post-result=$post)"
done

if $watch && ! $dry; then
  pr=${go[0]}; run_id=""
  for _ in $(seq 20); do
    sleep 3
    run_id=$(run_for_pr "$pr" || true)
    [[ -n "$run_id" && "$run_id" != "$before" ]] && break
    run_id=""
  done
  [[ -n "$run_id" ]] || die "the run for #$pr has not appeared yet; see https://github.com/$REPO/actions"
  echo "watching run $run_id: https://github.com/$REPO/actions/runs/$run_id"
  gh run watch -R "$REPO" "$run_id" --exit-status \
    || die "run $run_id did not finish successfully (cancelled or crashed): https://github.com/$REPO/actions/runs/$run_id"
  echo "run finished. Package failures do not fail the run; scripts/triage-failures.sh $pr explains any."
fi
