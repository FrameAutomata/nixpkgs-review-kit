#!/usr/bin/env bash
# Shared configuration and helpers for the review scripts. Source it, do not run it:
#   . "$(dirname "$(readlink -f "$0")")/lib.sh"

NIXPKGS_REPO=NixOS/nixpkgs
REPO="${NRGHA_REPO:-FrameAutomata/nixpkgs-review-gha}"   # your nixpkgs-review-gha fork
KIT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DEFAULT_SYSTEM=x86_64-linux   # what a report means when it names no system
NIXPKGS_DIR="${NIXPKGS_DIR:-$HOME/Dev/nixpkgs}"   # local nixpkgs checkout for local-review.sh
NIXPKGS_REVIEW_CACHE="${NIXPKGS_REVIEW_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nixpkgs-review}"   # per-PR working copies

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
# pr_base pr_base_sha pr_rebuilds pr_labels pr_bot pr_author pr_head_sha pr_updated pr_title,
# writes the PR body to BODYFILE, and fails if the PR could not be read.
# author and headRefOid ride along free: fetching them separately cost two extra
# round trips on a request that was already asking for nine fields.
pr_meta() {
  {
    IFS=$US read -r pr_state pr_draft pr_decision pr_approvals pr_base pr_base_sha pr_rebuilds pr_labels pr_bot pr_author pr_head_sha pr_updated pr_title \
      && cat > "$2"
  } < <(gh pr view "$1" -R "$NIXPKGS_REPO" \
          --json state,isDraft,reviewDecision,latestReviews,baseRefName,baseRefOid,labels,body,title,author,headRefOid,updatedAt \
          --jq '([ .state,
                   (.isDraft | tostring),
                   ((.reviewDecision // "") | if . == "" then "-" else . end),
                   ([.latestReviews[]? | select(.state == "APPROVED")] | length | tostring),
                   .baseRefName,
                   .baseRefOid,
                   ([.labels[].name | select(startswith("10.rebuild-")) | ltrimstr("10.rebuild-")] | join(",")),
                   ([.labels[].name] | join("; ")),
                   '"$BOT_REPORT_JQ"',
                   (.author.login // "-"),
                   .headRefOid,
                   .updatedAt,
                   .title ] | join("\u001f")),
                (.body // "")' 2>/dev/null)
}

# run_for_pr PR [completed]: id of the fork's newest review run for PR. Run titles
# are "review #PR" or "review #PR (<extra-args>)". With "completed", only runs
# that finished successfully count: package failures do not fail a run, while a
# cancelled or crashed run has no report. Prints nothing if there is none.
#
# The HTTP request does not depend on PR: it lists the whole workflow's runs and
# the PR filter is applied locally. One listing therefore serves every PR in a
# tick, so it is cached briefly — uncached it was issued 6-9 times per
# queue.sh tick at about a second each. RUNS_CACHE_TTL=0 disables the cache.
# The cache holds id<TAB>title<TAB>conclusion, flattened by gh's *built-in* jq at
# fetch time. Filtering it needs only awk: the standalone `jq` binary is not a
# dependency of this kit and is not installed everywhere `gh` is.
# RUNS_CACHE_TTL=0 forces a fresh listing — gha-review.sh --watch sets it,
# because it is polling for a run that does not exist yet.
RUNS_CACHE_TTL=${RUNS_CACHE_TTL:-60}
run_for_pr() {
  local cache="${TMPDIR:-/tmp}/nrk-runs-${UID:-0}-${REPO//\//_}.tsv" age=$((RUNS_CACHE_TTL + 1))
  [[ -f "$cache" ]] && age=$(( EPOCHSECONDS - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
  if (( age > RUNS_CACHE_TTL )); then
    if gh run list -R "$REPO" --workflow review.yml --limit 100 \
         --json databaseId,displayTitle,conclusion \
         --jq '.[] | [.databaseId, .displayTitle, .conclusion] | @tsv' > "$cache.tmp" 2>/dev/null; then
      mv "$cache.tmp" "$cache"
    else
      # Keep serving a stale listing rather than failing the whole tick.
      rm -f "$cache.tmp"; [[ -f "$cache" ]] || return 1
    fi
  fi
  awk -F'\t' -v pr="$1" -v need="${2:-}" '
    $2 == "review #" pr || index($2, "review #" pr " (") == 1 {
      if (need == "completed" && $3 != "success") next
      print $1; exit
    }' "$cache"
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
  awk -v label="${2:-report}" -v sys="${3:-$DEFAULT_SYSTEM}" '
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

# ---- reading a PR's package file ------------------------------------------

# pkg_files PR TMPDIR: fetch the PR's package file at its head commit and
# reconstruct the base version by reversing the diff onto it. Reversing beats
# fetching the base ref: it gives exactly what the PR started from, even when
# master has moved on. Writes TMPDIR/{full.diff,one.diff,head.nix,base.nix} and
# sets pkg_path and pkg_nfiles. Returns non-zero if the PR changes no .nix file.
pkg_files() {
  local pr=$1 t=$2 head_sha files=()
  # Callers run pr_meta first, which already fetched the head sha; only pay for
  # a second round trip when it was not set.
  head_sha="${pr_head_sha:-}"
  [[ -n "$head_sha" ]] || head_sha=$(gh pr view "$pr" -R "$NIXPKGS_REPO" --json headRefOid --jq .headRefOid) || return 1
  gh pr diff "$pr" -R "$NIXPKGS_REPO" > "$t/full.diff" || return 1
  mapfile -t files < <(sed -n 's|^+++ b/||p' "$t/full.diff" | grep '\.nix$' || true)
  [[ ${#files[@]} -gt 0 ]] || return 1
  # Prefer a package file. The diff is ordered by path, so a PR that also
  # touches maintainers/maintainer-list.nix or nixos/modules/*.nix would
  # otherwise be analysed against the wrong file.
  pkg_path="${files[0]}"; pkg_nfiles=${#files[@]}
  local f
  for f in "${files[@]}"; do
    if [[ $f == pkgs/* ]]; then pkg_path="$f"; break; fi
  done

  gh api "repos/$NIXPKGS_REPO/contents/$pkg_path?ref=$head_sha" --jq .content \
    | base64 -d > "$t/head.nix" || return 1
  awk -v f="$pkg_path" '
    index($0, "diff --git a/" f " b/" f) == 1 { on = 1; print; next }
    /^diff --git / { on = 0 }
    on { print }' "$t/full.diff" > "$t/one.diff"
  mkdir -p "$t/w/$(dirname "$pkg_path")"
  cp "$t/head.nix" "$t/w/$pkg_path"
  # Reversing an *added* file's diff succeeds and deletes it, so the file's
  # absence afterwards is the "new package" case, not a patch failure.
  if patch -Rs -p1 -d "$t/w" -i "$t/one.diff" 2>/dev/null && [[ -f "$t/w/$pkg_path" ]]; then
    cp "$t/w/$pkg_path" "$t/base.nix"
  else
    : > "$t/base.nix"   # new package, or a diff we could not reverse
  fi
}

# nix_str FILE ATTR -> the string value of `ATTR = "...";`
nix_str() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }

# nix_block FILE ATTR -> the lines of `ATTR = ... ;`. The attribute ends at the
# first `;` outside any bracket; a leading `with pkgs;` clause does not count,
# which is what makes `dependencies = with python3.pkgs; ( [ ... ] );` work.
nix_block() {
  awk -v attr="$2" '
    !on && $0 ~ "^[[:space:]]*" attr "[[:space:]]*=" { on = 1; bal = 0 }
    on {
      print
      n = split($0, ch, "")
      for (i = 1; i <= n; i++) {
        c = ch[i]
        if (c == "[" || c == "(" || c == "{") bal++
        else if (c == "]" || c == ")" || c == "}") bal--
      }
      # A trailing comment after `];` still ends the attribute.
      if (bal <= 0 && $0 ~ /;[[:space:]]*(#.*)?$/ && $0 !~ /^[[:space:]]*with[[:space:]]/) on = 0
    }' "$1"
}

# nix_items FILE ATTR -> the item names in that block, one per line.
# Two shapes appear in these lists and they reduce differently:
#   attribute paths  python3.pkgs.foo -> foo        (last component)
#   file paths       ./patches/fix.patch -> fix.patch (base name, extension kept,
#                    so two different patches do not both reduce to "patch")
# The noise filter runs *after* reduction: `lib.optionals` only becomes the
# filterable `optionals` once its prefix is gone.
nix_items() {
  nix_block "$1" "$2" \
    | sed "1s/^[^=]*=//" \
    | sed 's/\(^\|[[:space:]]\)#.*//' \
    | grep -oE '\.{0,2}/[A-Za-z0-9_./-]+|[A-Za-z_][A-Za-z0-9_.-]*' \
    | awk '{ if (index($0, "/")) sub(/.*\//, ""); else sub(/.*\./, ""); print }' \
    | grep -vxE 'with|lib|optionals|optional|final|finalAttrs|python3|python3Packages|pkgs|stdenv|hostPlatform|isLinux|isDarwin|isx86_64|true|false' \
    | sed '/^$/d' | sort -u || true
  # `|| true`: an absent attribute yields no lines, and the greps then exit 1,
  # which under the caller's `pipefail` would abort the whole script. Absent and
  # empty are the same answer here — no items — so report it as success.
}

# attr_of PATH TITLE -> the nixpkgs attribute name for a changed package file.
attr_of() {
  local a; a=$(sed -n 's|^pkgs/by-name/[^/]*/\([^/]*\)/.*|\1|p' <<<"$1")
  [[ -n "$a" ]] || a=$(sed 's/:.*//' <<<"$2")
  echo "$a"
}

# src_tag FILE VERSION -> the upstream tag or rev the package fetches, with
# `${version}` references resolved. Handles the quoted form
# (`tag = "v${finalAttrs.version}";`) and the unquoted one
# (`tag = finalAttrs.version;`), which nix_str cannot see and which silently
# disabled the upstream-metadata checks for packages written that way.
src_tag() {
  local t
  t=$(nix_str "$1" tag); [[ -n "$t" ]] || t=$(nix_str "$1" rev)
  if [[ -z "$t" ]]; then
    t=$(sed -n 's/^[[:space:]]*\(tag\|rev\)[[:space:]]*=[[:space:]]*\([^";]*\);.*/\2/p' "$1" | head -1)
    [[ "$t" == *version* ]] && t="$2"
  fi
  t=${t//\$\{finalAttrs.version\}/$2}; t=${t//\$\{version\}/$2}
  echo "$t"
}

# extract_built FILE -> one built package attribute per line. The sibling of
# extract_failures: same report markup, same <li> scrub, opposite <summary>.
# Kept here so a change to nixpkgs-review-gha's report format is one edit.
extract_built() {
  awk '/<summary>/ { on = ($0 ~ /built/) } /<\/ul>/ { on = 0 }
       on && /<li>/ { gsub(/.*<li>|<\/li>.*/, ""); sub(/ \(.*/, ""); print }' "$1" | sort -u
}

# report_systems FILE -> the systems a report covers, comma separated. Lives
# beside extract_built so the report's grammar has a single owner.
report_systems() {
  grep -oE '^### `[^`]+`' "$1" 2>/dev/null | tr -d '#` ' | paste -sd', ' - || true
}

# changelog_urls BODYFILE [N] -> up to N upstream changelog/release links from a
# PR body, nixpkgs' own links excluded.
changelog_urls() {
  grep -oE 'https://[^ )]*(releases|changelog|CHANGELOG|tag/)[^ )]*' "$1" 2>/dev/null \
    | grep -v "$NIXPKGS_REPO" | head -"${2:-1}" || true
}

# pr_and_out SUFFIX "$@": the argument handling shared by notes.sh and review.sh.
# Validates the PR number, honours `-o FILE` ("-" meaning stdout), rejects
# unknown options the way the older scripts do, and sets `pr` and `out`.
pr_and_out() {
  local suffix=$1; shift
  case "${1:-}" in '' | -h | --help) usage; exit 2 ;; esac
  [[ $1 =~ ^[0-9]+$ ]] || die "PR must be a number, got: $1"
  pr=$1; shift
  out="$KIT/reports/$pr-$suffix"
  if [[ "${1:-}" == -o ]]; then out="${2:?-o needs a value}"; shift 2; fi
  [[ $# -eq 0 ]] || die "unexpected argument: $1"
  [[ "$out" == - ]] && out=/dev/stdout
  # reports/ is git-ignored, so it does not exist in a fresh clone.
  [[ "$out" == /dev/stdout ]] || mkdir -p "$(dirname "$out")"
}
