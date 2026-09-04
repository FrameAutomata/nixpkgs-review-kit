#!/usr/bin/env bash
# Fill in the review template for one PR with the facts the kit already knows.
#
# Usage: scripts/review.sh PR [-o FILE]
#   -o FILE   where to write (default: reports/PR-review.md; "-" for stdout)
#
# The checklist wording comes from templates/review-comment.md, which mirrors
# nixpkgs' own PR template — this script renders that file rather than keeping a
# second copy of it, so upstream wording changes in one place.
#
# Each item ends up in one of three states, and the marker is emitted by the
# mechanism rather than typed into the text:
#   [x]        decidable from the diff or the build report; the evidence is shown
#   [ ] YOU:   a claim about what a person did or judged; never auto-ticked
#   [ ] N/A:   does not apply here, which is not the same as done
# "Executables tested" is not something a script can know, and a template that
# pre-ticks it produces reviews asserting work nobody performed.
#
# Nothing here is a review. Read it, do the YOU: items, write the prose.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

pr_and_out review.md "$@"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pr_meta "$pr" "$tmp/body.md" || die "cannot read PR #$pr"
pkg_files "$pr" "$tmp" || die "#$pr changes no .nix file"

old_ver=$(nix_str "$tmp/base.nix" version); new_ver=$(nix_str "$tmp/head.nix" version)
attr=$(attr_of "$pkg_path" "$pr_title")
report="$KIT/reports/$pr-gha.md"; testlog="$KIT/reports/$pr-testlog.md"

# ---- evidence -------------------------------------------------------------

# A report saved before the PR was last updated describes a superseded commit —
# a force-push after the build would otherwise be ticked as "builds". Decided
# before anything is read out of the report, so a disowned run cannot still be
# cited as the build link further down.
stale_report=false
if [[ -f "$report" && -n "$pr_updated" ]]; then
  upd=$(date -d "$pr_updated" +%s 2>/dev/null || echo 0)
  (( upd > 0 && upd > $(stat -c %Y "$report") )) && stale_report=true
fi

built=""; run_url=""; systems=""; nfailed=0
if [[ -f "$report" ]] && ! $stale_report; then
  built=$(extract_built "$report" | paste -sd' ' -)
  run_url=$(grep -oE 'https://github.com/[^ )]*/actions/runs/[0-9]+' "$report" | head -1 || true)
  systems=$(report_systems "$report")
  nfailed=$(extract_failures "$report" | grep -cvE 'still-failing|unsupported' || true)
fi
systems=${systems:-$DEFAULT_SYSTEM}

# Is the new version a real upstream release? Evidence for the "upstream
# verified" item; it does not tick it, because reading the changelog is the work.
rel=""
owner=$(nix_str "$tmp/head.nix" owner); repo=$(nix_str "$tmp/head.nix" repo)
tag=$(src_tag "$tmp/head.nix" "$new_ver")
if [[ -n "$owner" && -n "$repo" && -n "$tag" ]]; then
  rel=$(gh api "repos/$owner/$repo/releases/tags/$tag" \
          --jq 'if .prerelease then "prerelease" elif .draft then "draft" else "release published \(.published_at[0:10])" end' 2>/dev/null || true)
fi
changelog=$(changelog_urls "$tmp/body.md" 1)

# ---- checklist decisions --------------------------------------------------
declare -A STATE EV

# name: for an update the attribute is unchanged, so it still fits by construction.
if [[ -n "$old_ver" && "$pkg_path" == pkgs/by-name/* ]]; then
  STATE[name]=yes; EV[name]="\`$attr\`, unchanged by this PR, under pkgs/by-name"
else
  STATE[name]=no;  EV[name]="new package or renamed attribute — check against the naming rules"
fi

# version: no leading v; unstable versions must be 0-unstable-YYYY-MM-DD and
# their date must match the pinned rev, which only a person can confirm.
if [[ -z "$new_ver" ]]; then
  STATE[version]=no; EV[version]="could not read a version from the package — check by hand"
elif [[ "$new_ver" == v[0-9]* ]]; then
  STATE[version]=no; EV[version]="\`$new_ver\` starts with 'v', which nixpkgs does not want"
elif [[ "$new_ver" == *unstable* ]]; then
  if [[ "$new_ver" =~ ^0-unstable-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    STATE[version]=no; EV[version]="\`$new_ver\` has the right shape, but confirm the date matches the pinned rev's commit date"
  else
    STATE[version]=no; EV[version]="\`$new_ver\` does not match 0-unstable-YYYY-MM-DD"
  fi
else
  STATE[version]=yes; EV[version]="\`$new_ver\`${rel:+, upstream $rel}"
fi

# builds / dependents: the saved report is the evidence, and it is linked below.
# One branch per predicate, no mutated state steering the control flow.
if $stale_report; then
  STATE[builds]=no; EV[builds]="reports/$pr-gha.md predates the PR's last update ($pr_updated) — rebuild with scripts/gha-review.sh $pr"
  STATE[dependents]=no; EV[dependents]="no usable build report"
elif [[ -z "$built" ]]; then
  STATE[builds]=no; EV[builds]="no build report at reports/$pr-gha.md; run scripts/gha-review.sh $pr"
  STATE[dependents]=no; EV[dependents]="no build report to read"
elif (( nfailed > 0 )); then
  STATE[builds]=no; EV[builds]="the report lists $nfailed failure(s); see reports/$pr-triage.txt"
  STATE[dependents]=no; EV[dependents]="the report lists failures; triage them first"
else
  STATE[builds]=yes; EV[builds]="$systems: built $built${run_url:+, $run_url}"
  if [[ "$built" == "$attr" ]]; then
    STATE[dependents]=yes; EV[dependents]="leaf package: the report built only \`$attr\`"
  else
    STATE[dependents]=yes; EV[dependents]="the report built $built with no failures"
  fi
fi

STATE[tested]=no;    EV[tested]="only you know what you ran; paste it under Tested"
STATE[upstream]=no;  EV[upstream]="read the changelog${changelog:+ — $changelog}${rel:+ (the tag is a $rel)}"
STATE[choices]=no;   EV[choices]="a judgement call on this diff"

if nix_items "$tmp/head.nix" patches | grep -q .; then
  STATE[patch1]=no; EV[patch1]="this package has patches — check each one's provenance comment"
  STATE[patch2]=no; EV[patch2]="this package has patches — check they are fetched, not vendored"
else
  STATE[patch1]=na; EV[patch1]="this package has no patches"
  STATE[patch2]=na; EV[patch2]="this package has no patches"
fi

# Map a template checklist line to its key by a distinctive substring. An item
# we do not recognise falls through to "YOU:", so a wording change upstream
# degrades to "a human must decide" rather than to a silent wrong tick.
key_for() {
  case "$1" in
    *"package name"*)                 echo name ;;
    *"package version"*)              echo version ;;
    *"builds on"*)                    echo builds ;;
    *"executables tested"*)           echo tested ;;
    *"change of upstream"*)           echo upstream ;;
    *"special packaging choices"*)    echo choices ;;
    *"depending packages"*)           echo dependents ;;
    *"upstreamed"*)                   echo patch1 ;;
    *"vendored"*)                     echo patch2 ;;
  esac
}

# ---- render the template --------------------------------------------------
ticked=()
{
  seen_heading=false
  while IFS= read -r line; do
    case "$line" in
      '#####'*)
        $seen_heading && echo
        seen_heading=true; echo "$line"; echo
        case "$line" in
          *Tested*)
            if [[ -f "$testlog" ]]; then
              echo "<!-- Lifted from reports/$pr-testlog.md. Keep ONLY the commands you"
              echo "     ran yourself, and rewrite any prose in your own words. -->"
              echo
              awk '/^## Commands run/ { on = 1; next } /^## / { on = 0 } on' "$testlog"
            else
              echo "<!-- YOU: exact commands and verbatim output. Build it first:"
              echo "     scripts/local-review.sh $pr --no-shell"
              echo "     then run the binary from"
              echo "     $NIXPKGS_REVIEW_CACHE/pr-$pr/results/$attr-$DEFAULT_SYSTEM/bin/ -->"
            fi ;;
          *improvements*)
            echo "<!-- YOU: anything non-blocking you noticed. reports/$pr-notes.md lists"
            echo "     what to look at; nothing from it belongs here until you confirm it. -->" ;;
          *Comments*)
            echo "Build check run on my [nixpkgs-review-gha](https://github.com/$REPO) fork${run_url:+: $run_url}."
            echo
            echo "<!-- YOU: if any wording in this comment came from an AI assistant, say so"
            echo "     here, per the nixpkgs automation/AI policy. Research and testing help"
            echo "     is exempt; text that lands in the comment is not. -->" ;;
        esac ;;
      '- [ ] '*)
        # Quote the prefix: unquoted, `[ ]` is a glob character class and strips nothing.
        # `key` must never be empty: an empty associative-array subscript is a
        # hard error in bash, even with a `:-` default on the expansion.
        item="${line#"- [ ] "}"; key=$(key_for "$item"); key=${key:-none}
        case "${STATE[$key]:-no}" in
          yes) printf -- '- [x] %s <!-- %s -->\n' "$item" "${EV[$key]}"; ticked+=("$key") ;;
          na)  printf -- '- [ ] %s <!-- N/A: %s -->\n' "$item" "${EV[$key]}" ;;
          *)   printf -- '- [ ] %s <!-- YOU: %s -->\n' "$item" "${EV[$key]:-not recognised by review.sh; decide by hand}" ;;
        esac ;;
      '<!--'*|'') ;;   # drop the template's own instructions and blank lines
      *) echo "$line" ;;
    esac
  done < "$KIT/templates/review-comment.md"
} > "$out"

# What still needs a person, on stderr so it never lands in the comment.
{
  # `ticked` was filled by the render loop above — a `{ ... } > file` group is
  # not a subshell and `done < file` is not a pipe, so the appends survive. That
  # also means the order comes from the template rather than a third hand-kept list.
  [[ "$out" == /dev/stdout ]] || echo "wrote ${out/#$KIT\//}"
  echo "auto-ticked: ${ticked[*]:-none}"
  echo "still yours: executables tested, upstream changes verified, packaging choices, and the prose"
  if [[ -f "$KIT/reports/$pr-notes.md" ]]; then echo "notes to read first: reports/$pr-notes.md"; fi
} >&2
