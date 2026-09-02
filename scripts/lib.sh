#!/usr/bin/env bash
# Shared configuration and helpers for the review scripts. Source it, do not run it:
#   . "$(dirname "$(readlink -f "$0")")/lib.sh"

NIXPKGS_REPO=NixOS/nixpkgs
REPO="${NRGHA_REPO:-FrameAutomata/nixpkgs-review-gha}"   # your nixpkgs-review-gha fork
KIT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DEFAULT_SYSTEM=x86_64-linux   # what a report means when it names no system
NIXPKGS_DIR="${NIXPKGS_DIR:-$HOME/Dev/nixpkgs}"   # local nixpkgs checkout for local-review.sh

# Print the calling script's leading comment block as its help text.
usage() { awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; }
die() { echo "$*" >&2; exit 1; }

# Field separator for records read with `read`: the ASCII unit separator (U+001F).
# Unlike tab it is not IFS whitespace, so empty fields survive.
US=$'\x1f'

# jq snippet: verdict of the update bot's own nixpkgs-review result in a PR body.
#   bot:FAIL  a red :x: appears in the bot's "Pre-merge build results" section
#   bot:ok    the section exists and shows no :x:
#   -         no bot report (human-authored PR)
# A cheap heuristic for listings; triage parses the body properly with extract_failures.
BOT_REPORT_JQ='((.body // "") | if test("Pre-merge build results[\\s\\S]*:x:") then "bot:FAIL"
                               elif test("Pre-merge build results") then "bot:ok" else "-" end)'

# pr_meta PR BODYFILE: one API call. Sets pr_state pr_draft pr_decision pr_approvals
# pr_base pr_base_sha pr_rebuilds pr_labels pr_bot pr_title, writes the PR body to
# BODYFILE, and fails if the PR could not be read.
pr_meta() {
  {
    IFS=$US read -r pr_state pr_draft pr_decision pr_approvals pr_base pr_base_sha pr_rebuilds pr_labels pr_bot pr_title \
      && cat > "$2"
  } < <(gh pr view "$1" -R "$NIXPKGS_REPO" \
          --json state,isDraft,reviewDecision,latestReviews,baseRefName,baseRefOid,labels,body,title \
          --jq '([ .state,
                   (.isDraft | tostring),
                   ((.reviewDecision // "") | if . == "" then "-" else . end),
                   ([.latestReviews[]? | select(.state == "APPROVED")] | length | tostring),
                   .baseRefName,
                   .baseRefOid,
                   ([.labels[].name | select(startswith("10.rebuild-")) | ltrimstr("10.rebuild-")] | join(",")),
                   ([.labels[].name] | join("; ")),
                   '"$BOT_REPORT_JQ"',
                   .title ] | join("\u001f")),
                (.body // "")' 2>/dev/null)
}

# run_for_pr PR [completed]: id of the fork's newest review run for PR. Run titles
# are "review #PR" or "review #PR (<extra-args>)". With "completed", only runs
# that finished successfully count: package failures do not fail a run, while a
# cancelled or crashed run has no report. Prints nothing if there is none.
run_for_pr() {
  local cond="(.displayTitle == \"review #$1\" or (.displayTitle | startswith(\"review #$1 (\")))"
  [[ "${2:-}" == completed ]] && cond+=' and .conclusion == "success"'
  gh run list -R "$REPO" --workflow review.yml --limit 100 --json databaseId,displayTitle,conclusion \
    --jq "first(.[] | select($cond)) | .databaseId // empty"
}

# gha_report PR FILE: save the merged report of PR's newest successful run to
# FILE unless FILE already holds it. Prints the run id once FILE holds its
# report, nothing otherwise. The report.md artifact is stored uncompressed, so
# the artifact "zip" endpoint returns plain Markdown (`gh run download` rejects it).
gha_report() {
  local run aid
  run=$(run_for_pr "$1" completed) || return 0
  [[ -n "$run" ]] || return 0
  if ! grep -qs "/runs/$run/" "$2"; then
    aid=$(gh api "repos/$REPO/actions/runs/$run/artifacts" \
            --jq 'first(.artifacts[] | select(.name == "report.md" and .expired == false)) | .id // empty') || return 0
    [[ -n "$aid" ]] || return 0
    mkdir -p "$(dirname "$2")"
    if gh api "repos/$REPO/actions/artifacts/$aid/zip" > "$2.tmp" 2>/dev/null; then
      mv "$2.tmp" "$2"
    else
      rm -f "$2.tmp"; return 0
    fi
  fi
  echo "$run"
}

# extract_failures FILE LABEL [SYSTEM]
# -> LABEL<TAB>system<TAB>kind<TAB>attr for every failed package, kind being
#    failed | still-failing | unsupported, plus one "crashed" row when the report
#    says nixpkgs-review itself failed (the update bot prints ":x: nixpkgs-review failed").
# Parses nixpkgs-review's Markdown (local runs, the update bot's PR body) and
# nixpkgs-review-gha's compact variant. Reports without a "### `system`" header
# get SYSTEM (default: DEFAULT_SYSTEM). Alias suffixes like "foo (bar, baz)" are dropped.
extract_failures() {
  awk -v label="$2" -v sys="${3:-$DEFAULT_SYSTEM}" '
    /^### `/ { match($0, /`[^`]+`/); sys = substr($0, RSTART + 1, RLENGTH - 2); next }
    /<summary>/ {
      kind = ""
      if ($0 ~ /still failing to build/)            kind = "still-failing"
      else if ($0 ~ /failed to build/)              kind = "failed"
      else if ($0 ~ /not supported on this runner/) kind = "unsupported"
      else if ($0 ~ /:x:/)                          kind = "failed"   # unknown wording, do not hide it
      next
    }
    /^:x: nixpkgs-review failed/ { print label "\t" sys "\tcrashed\t(nixpkgs-review itself)"; next }
    /<\/ul>/ { kind = ""; next }
    kind != "" && /<li>/ {
      gsub(/.*<li>|<\/li>.*/, ""); sub(/ \(.*/, "")
      print label "\t" sys "\t" kind "\t" $0
    }
  ' "$1"
}
