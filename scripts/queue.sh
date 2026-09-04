#!/usr/bin/env bash
# Keep a batch of nixpkgs-review-gha builds in flight and triage them as they land,
# so PRs are waiting for you with the mechanical work already done.
#
# Usage: scripts/queue.sh [options] [COMMAND] [PR...]
#   tick            one pass: collect finished builds, then top up to --max (default)
#   run             tick every --interval seconds until interrupted
#   add PR...       queue specific PRs, ignoring --tier and the candidate search
#   status          what is in each bucket
#   done PR...      mark PRs handled (you posted a review, or decided not to) and
#                   delete nixpkgs-review's working copy for them
#   drop PR...      forget PRs entirely; they can be picked again
#
# Options:
#   --max N         builds in flight at once (default: 3)
#   --tier T        rebuild tier to pick candidates from, as in find-prs.sh (default: 1)
#   --interval S    seconds between ticks in "run" mode (default: 300)
#   --timeout S     give up on a build with no report after this long (default: 21600, the runner limit)
#   --no-fill       collect only, never dispatch anything new
#   --dry-run       print what would be dispatched instead of dispatching
#   --keep-cache    keep nixpkgs-review's per-PR working copy after "done"
#   --notify CMD    run CMD PR BUCKET TITLE NOTES-PATH COUNT when a build lands
#                   (default: notify-send when installed, plus a banner and a bell)
#
# A PR moves through four buckets:
#   in-flight  dispatched, waiting for the fork's run to finish
#   ready      report landed and either built clean or triage explained every failure
#   attention  triage found a failure Hydra builds fine on base, or no report ever arrived
#   skipped    gha-review.sh pre-flight refused it; kept so it is not picked again
# When a build lands, notes.sh writes a test plan to reports/PR-notes.md and the
# result is announced. State lives in reports/queue/ (git-ignored). Reports land
# in reports/PR-gha.md and triage output in reports/PR-triage.txt.
#
# What this does NOT do: read diffs, run the built binaries, or post anything.
# It is the "not building what you do not have to" part of the workflow only;
# nixpkgs wants a person in the loop for the rest (README, "Rules").
set -euo pipefail
shopt -s nullglob
. "$(dirname "$(readlink -f "$0")")/lib.sh"

QUEUE="${QUEUE_DIR:-$KIT/reports/queue}"
BUCKETS=(in-flight ready attention skipped)

max=3; tier=1; interval=300; timeout=$((6 * 3600)); do_fill=true; dry=false; notify_cmd=""; clean_cache=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max) max="${2:?--max needs a value}"; shift ;;
    --tier) tier="${2:?--tier needs a value}"; shift ;;
    --interval) interval="${2:?--interval needs a value}"; shift ;;
    --timeout) timeout="${2:?--timeout needs a value}"; shift ;;
    --no-fill) do_fill=false ;;
    --dry-run) dry=true ;;
    --notify) notify_cmd="${2:?--notify needs a value}"; shift ;;
    --keep-cache) clean_cache=false ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage; exit 2 ;;
    *) break ;;
  esac
  shift
done

if (( $# )); then cmd=$1; shift; else cmd=tick; fi
prs=("$@")
for pr in "${prs[@]}"; do
  [[ $pr =~ ^[0-9]+$ ]] || die "PR must be a number, got: $pr"
done

mkdir -p "${BUCKETS[@]/#/$QUEUE/}"

# A queue entry is one line: dispatched<US>run<US>prev<US>title. The unit
# separator keeps an empty run id (still building) from swallowing the title.
# `prev` is the newest completed run that already existed when this PR was
# dispatched; without it, re-queuing a PR that was built earlier reads that old
# run's report and marks the PR ready seconds later.
place() {   # place BUCKET PR DISPATCHED RUN PREV TITLE; removes PR from every other bucket
  forget "$2"
  printf '%s\n' "$3$US$4$US$5$US$6" > "$QUEUE/$1/$2"
}
get() {     # get BUCKET PR -> q_dispatched q_run q_prev q_title
  q_dispatched=0; q_run=""; q_prev=""; q_title=""
  IFS=$US read -r q_dispatched q_run q_prev q_title < "$QUEUE/$1/$2" || true
  # Entries written before `prev` existed have three fields, so the title landed
  # in q_prev. A run id is all digits; a title is not. Self-limiting: place()
  # rewrites a record in 4-field form whenever a PR moves. Delete this branch
  # once your queue has drained past 2026-09; reports/ is git-ignored scratch.
  if [[ -z "$q_title" && -n "$q_prev" && ! "$q_prev" =~ ^[0-9]+$ ]]; then
    q_title="$q_prev"; q_prev=""
  fi
}
bucket_of() {
  local b
  for b in "${BUCKETS[@]}"; do [[ -f "$QUEUE/$b/$1" ]] && { echo "$b"; return 0; }; done
  return 1
}
# clean_pr_cache PR: drop nixpkgs-review's working copy for a PR. What this
# frees is the nixpkgs checkout it keeps per PR, a few hundred MB. The packages
# it built are in /nix/store with no GC root pointing at them, so those are
# already garbage and the weekly nix-gc collects them; there is nothing here to
# uninstall.
clean_pr_cache() {
  local d="$NIXPKGS_REVIEW_CACHE/pr-$1" sz
  [[ -d "$d" ]] || return 0
  # `|| true` as well as the fallback: under pipefail a failing du would abort
  # `done` here, after forget() ran but before the cache is actually removed.
  sz=$(du -sh "$d" 2>/dev/null | cut -f1 || true); sz=${sz:-?}
  rm -rf "$d"
  echo "  #$1 freed $sz of working copy"
}
forget() { local b; for b in "${BUCKETS[@]}"; do rm -f "$QUEUE/$b/$1"; done; }
age() {     # age EPOCH -> 12m | 3h | 2d
  local m=$(( (EPOCHSECONDS - $1) / 60 ))
  if (( m < 60 )); then echo "${m}m"; elif (( m < 1440 )); then echo "$((m / 60))h"; else echo "$((m / 1440))d"; fi
}

# announce PR BUCKET TITLE: write the test plan for a PR that just finished
# building and tell the user it is waiting. Notes are best effort; a PR still
# lands in its bucket if notes.sh cannot read the diff.
announce() {
  local pr=$1 bucket=$2 title=$3 notes="" n=0 line
  notes=$("$KIT/scripts/notes.sh" "$pr" 2>/dev/null) || notes=""
  if [[ -n "$notes" ]]; then
    # Heading produced by notes.sh; keep in step with it.
    n=$(awk '/^## Watch out for/ { on = 1; next } /^## / { on = 0 } on && /^- / { c++ } END { print c + 0 }' "$notes")
  fi

  # A custom notifier gets everything and decides for itself.
  if [[ -n "$notify_cmd" ]]; then
    "$notify_cmd" "$pr" "$bucket" "$title" "${notes:-}" "$n" || true
    return 0
  fi

  line="#$pr $bucket to test"
  [[ $bucket == attention ]] && line="#$pr needs a look before testing"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal "nixpkgs $line" "$title${notes:+ — $n things to watch out for}" || true
  fi
  # Always print the banner: the loop usually runs where nobody is watching a
  # desktop, and the bell is what carries across workspaces.
  printf '\a'
  printf '  ┌─ %s\n' "$line"
  printf '  │  %s\n' "$title"
  [[ -n "$notes" ]] && printf '  │  %s things to watch out for · %s\n' "$n" "${notes#"$KIT/"}"
  printf '  │  scripts/local-review.sh %s\n' "$pr"
  printf '  └─\n'
  return 0
}

# settle BUCKET MESSAGE: file the PR collect() is currently handling and tell
# the user. Reads collect()'s locals (pr, run, q_*) by dynamic scope, so it is
# only meaningful from inside that loop.
settle() {
  echo "  #$pr $1: $2"
  place "$1" "$pr" "$q_dispatched" "$run" "$q_prev" "$q_title"
  announce "$pr" "$1" "$q_title"
}

# collect: advance everything in flight. Cheap per PR: one PR read, one run
# lookup, and a triage run only when a report actually lists failures.
collect() {
  local f pr why run report triage
  for f in "$QUEUE/in-flight"/*; do
    pr=$(basename "$f"); get in-flight "$pr"

    # Drop PRs that stopped being worth your time while their build ran.
    why=""
    if pr_meta "$pr" /dev/null; then
      if [[ $pr_state != OPEN ]]; then why="PR is $pr_state"
      elif [[ $pr_decision == APPROVED || $pr_approvals != 0 ]]; then why="approved by someone else"
      fi
    fi
    if [[ -n "$why" ]]; then
      echo "  #$pr dropped: $why"
      forget "$pr"; continue
    fi

    report="$KIT/reports/$pr-gha.md"
    run=$(gha_report "$pr" "$report" || true)
    # A run id equal to the one recorded at dispatch is the *previous* build of
    # this PR, not ours; keep waiting for a newer one.
    [[ -n "$run" && "$run" == "$q_prev" ]] && run=""
    if [[ -z "$run" ]]; then
      # No finished run yet. A cancelled or crashed run never produces one, so
      # stop waiting eventually rather than holding a slot forever.
      if (( EPOCHSECONDS - q_dispatched > timeout )); then
        settle attention "no report after $(age "$q_dispatched"), check https://github.com/$REPO/actions"
      fi
      continue
    fi

    if [[ -z "$(extract_failures "$report" gha)" ]]; then
      settle ready "built clean (run $run)"
      continue
    fi

    # Failures: triage is the slow part (Hydra plus issue searches), so do it now
    # and let its own verdict decide whether this needs you.
    triage="$KIT/reports/$pr-triage.txt"
    # A crashed triage prints no verdict, and "no NEEDS A LOOK" would then read
    # as "all explained". Only a triage that actually succeeded can clear a PR.
    if ! "$KIT/scripts/triage-failures.sh" "$pr" > "$triage" 2>&1; then
      settle attention "the report lists failures and triage itself failed, see reports/$pr-triage.txt"
    elif grep -q 'NEEDS A LOOK' "$triage"; then
      settle attention "triage found a failure Hydra builds on base, see reports/$pr-triage.txt"
    else
      settle ready "failures all explained as pre-existing, see reports/$pr-triage.txt"
    fi
  done
}

# dispatch PR: 0 when a build actually started. gha-review.sh does its own
# pre-flight; anything it refuses goes to "skipped" so the next tick moves on.
dispatch() {
  local out title reason prev opts=()
  $dry && opts=(--dry-run)
  # Newest already-completed run for this PR, so collect can tell a stale
  # report from the one this dispatch produces.
  prev=$(run_for_pr "$1" completed 2>/dev/null || true)
  if ! out=$("$KIT/scripts/gha-review.sh" "${opts[@]}" "$1" 2>&1); then
    echo "  #$1 dispatch failed:"; sed 's/^/    /' <<<"$out"; return 1
  fi
  # Pre-flight prints "  #PR <title>" first, then "  #PR started on ..." on dispatch.
  title=$(sed -n "s/^  #$1 //p" <<<"$out" | head -1)
  if $dry; then
    echo "  #$1 would dispatch: $title"; return 0
  fi
  if ! grep -q "^  #$1 started" <<<"$out"; then
    reason=$(sed -n 's/^     pre-flight: SKIP, //p' <<<"$out" | head -1)
    echo "  #$1 skipped: ${reason:-pre-flight refused it}"
    place skipped "$1" "$EPOCHSECONDS" "" "$prev" "$title"
    return 1
  fi
  echo "  #$1 dispatched: $title"
  place in-flight "$1" "$EPOCHSECONDS" "" "$prev" "$title"
}

# fill WANT: dispatch up to WANT new PRs from the candidate search.
fill() {
  local want=$1 pr started=0 cands=()
  # Ask for more candidates than slots: pre-flight rejects some, and PRs already
  # in the queue still show up in the search until they are merged or reviewed.
  mapfile -t cands < <("$KIT/scripts/find-prs.sh" --tier "$tier" $(( want * 4 )) \
                       | awk '{ sub(/^#/, "", $1); print $1 }')
  for pr in "${cands[@]}"; do
    (( started < want )) || break
    bucket_of "$pr" >/dev/null && continue
    dispatch "$pr" && started=$(( started + 1 )) || true
  done
  (( started > 0 )) || echo "  nothing new to dispatch"
}

tick() {
  local in_flight want
  echo "collect:"
  collect
  local n=("$QUEUE/in-flight"/*); in_flight=${#n[@]}
  if $do_fill; then
    want=$(( max - in_flight ))
    echo "dispatch: $in_flight in flight, room for $want"
    if (( want > 0 )); then fill "$want"; fi
  fi
}

status() {
  local b files f pr
  for b in "${BUCKETS[@]}"; do
    files=("$QUEUE/$b"/*)
    printf '%s (%d)\n' "$b" "${#files[@]}"
    for f in "${files[@]}"; do
      pr=$(basename "$f"); get "$b" "$pr"
      printf '  #%-7s %-5s %s\n' "$pr" "$(age "$q_dispatched")" "$q_title"
      # The run that produced the report, so a surprising verdict can be traced
      # back to its build without hunting through the Actions UI.
      [[ -n "$q_run" ]] && printf '  %-13s https://github.com/%s/actions/runs/%s\n' "" "$REPO" "$q_run"
    done
  done
  files=("$QUEUE/ready"/*)
  (( ${#files[@]} )) || return 0
  cat <<EOF

ready PRs still need you: read the diff, test the binaries, write the review.
  gh pr diff N -R $NIXPKGS_REPO
  scripts/local-review.sh N
  scripts/queue.sh done N
EOF
}

case "$cmd" in
  tick) tick ;;
  run)
    echo "ticking every ${interval}s, Ctrl-C to stop"
    while true; do
      echo "== $(date '+%Y-%m-%d %H:%M:%S')"
      tick
      sleep "$interval"
    done ;;
  add)
    [[ ${#prs[@]} -gt 0 ]] || die "add needs at least one PR number"
    for pr in "${prs[@]}"; do
      bucket_of "$pr" >/dev/null && { echo "  #$pr already queued"; continue; }
      dispatch "$pr" || true
    done ;;
  status) status ;;
  done|drop)
    [[ ${#prs[@]} -gt 0 ]] || die "$cmd needs at least one PR number"
    for pr in "${prs[@]}"; do
      b=$(bucket_of "$pr") || { echo "  #$pr not in the queue"; continue; }
      forget "$pr"
      echo "  #$pr removed from $b"
      if [[ $cmd == done ]] && $clean_cache; then clean_pr_cache "$pr"; fi
    done ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
esac
