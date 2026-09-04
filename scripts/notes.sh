#!/usr/bin/env bash
# Write a test plan for one PR: what changed, what to watch out for, what to run.
#
# Usage: scripts/notes.sh PR [-o FILE]
#   -o FILE   where to write (default: reports/PR-notes.md; "-" for stdout)
#
# Everything here is mechanical: it compares the PR's package file against its
# base version, and for Python packages compares the dependencies nixpkgs
# declares against the ones upstream declares at the new tag. Nothing is a
# verdict. The notes tell you where to look; the looking is still yours.
#
# Called automatically by queue.sh when a PR becomes ready, so the plan is
# waiting with the build.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

pr_and_out notes.md "$@"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pr_meta "$pr" "$tmp/body.md" || die "cannot read PR #$pr"

# Fetches the package file at head and reconstructs its base version; sets
# pkg_path and pkg_nfiles. PRs touching several .nix files are rarer and the
# notes then cover the first one only, which is said in the output.
pkg_files "$pr" "$tmp" || die "#$pr changes no .nix file; nothing to write notes about"

# Attribute changes, computed once. Both the "What changed" list and the
# "Watch out for" rules read these, so "did dependencies change?" has exactly
# one expression rather than one per section.
ATTRS=(build-system dependencies nativeBuildInputs buildInputs
       propagatedBuildInputs pythonRelaxDeps patches)
declare -A add rem
for a in "${ATTRS[@]}"; do
  add[$a]=$(comm -13 <(nix_items "$tmp/base.nix" "$a") <(nix_items "$tmp/head.nix" "$a") | paste -sd' ' -)
  rem[$a]=$(comm -23 <(nix_items "$tmp/base.nix" "$a") <(nix_items "$tmp/head.nix" "$a") | paste -sd' ' -)
done
in_diff() { grep -qE "$1" "$tmp/one.diff"; }
in_pkg()  { grep -qE "$1" "$tmp/head.nix"; }
maint_changed=false; in_diff '^\+.*maintainers *=' && maint_changed=true
license_changed=false; in_diff '^\+.*license *=' && license_changed=true

old_ver=$(nix_str "$tmp/base.nix" version); new_ver=$(nix_str "$tmp/head.nix" version)
attr=$(attr_of "$pkg_path" "$pr_title")
# The PR carries both a range label ("1-10") and an exact one ("1"); prefer exact.
rebuilds=$(tr "," "\n" <<<"$pr_rebuilds" | grep -v -- "-" | paste -sd", " - || true)
[[ -n "$rebuilds" ]] || rebuilds="$pr_rebuilds"
main=$(nix_str "$tmp/head.nix" mainProgram); main="${main:-$attr}"
# The review shell exposes results as ./results/<attr>-<system>, not ./results/<attr>.
bin="./results/$attr-$DEFAULT_SYSTEM/bin"

# ---- upstream Python dependencies ----------------------------------------
# Two checks, both against upstream's own metadata:
#   py_missing  upstream declares it, nixpkgs does not -> fails at runtime, in
#               whichever feature imports it; a green build cannot see this.
#   py_stale    upstream declared it at the OLD version and no longer does, but
#               nixpkgs still carries it -> a dependency the package dropped.
# py_stale compares old against new deliberately. "In nixpkgs but never in
# upstream metadata" is far too noisy to report: tkinter, dbus-next and other
# platform extras legitimately live only on the nixpkgs side.
py_missing=""; py_stale=""; py_source=""; py_skipped=""

# upstream_deps TAG OUTFILE -> upstream's declared runtime requirements at TAG,
# and sets py_source to the files it actually read. The old tag is fetched
# before the new one so py_source ends up describing the new tag by construction.
upstream_deps() {
  local url="https://raw.githubusercontent.com/$owner/$repo/$1" t=$2
  py_source=""
  : > "$t"
  # Two independent URLs: fetch them at once rather than serially, and cap the
  # worst case at one timeout instead of two.
  curl -sfL -m 20 "$url/pyproject.toml"   -o "$t.toml" & local p1=$!
  curl -sfL -m 20 "$url/requirements.txt" -o "$t.req"  & local p2=$!
  wait $p1 || : > "$t.toml"
  wait $p2 || : > "$t.req"
  if [[ -s "$t.toml" ]]; then
    awk '/^dependencies[[:space:]]*=[[:space:]]*\[/ { on = 1; next }
         on && /^\]/ { on = 0 } on { print }' "$t.toml" \
      | grep -oE '"[^"]+"' | tr -d '"' >> "$t" || true
    py_source="pyproject.toml"
  fi
  if [[ -s "$t.req" ]]; then
    grep -vE '^[[:space:]]*(#|-|$)' "$t.req" >> "$t" || true
    py_source="${py_source:+$py_source and }requirements.txt"
  fi
}

if in_pkg 'buildPythonApplication|buildPythonPackage'; then
  owner=$(nix_str "$tmp/head.nix" owner); repo=$(nix_str "$tmp/head.nix" repo)
  new_tag=$(src_tag "$tmp/head.nix" "$new_ver")
  old_tag=$(src_tag "$tmp/head.nix" "$old_ver")
  if [[ -z "$owner" || -z "$repo" || -z "$new_tag" ]]; then
    # fetchPypi and friends have no owner/repo, so there is nowhere to look.
    py_skipped="no GitHub owner/repo/tag in the package, so upstream metadata was not fetched"
  else
    # Normalise both sides the way PyPI does: lowercase, separators to dashes.
    # sed rather than grep for the blank-line drop: grep returns 1 when nothing
    # matches, which under `pipefail` kills the script whenever upstream's
    # metadata yields no dependencies at all.
    norm() { sed 's/[[:space:]]*\([<>=!~;[].*\)$//' | tr 'A-Z_.' 'a-z--' | sed 's/[^a-z0-9-]//g; /^$/d' | sort -u; }
    { nix_items "$tmp/head.nix" dependencies
      nix_items "$tmp/head.nix" propagatedBuildInputs; } > "$tmp/nixdeps.raw"
    norm < "$tmp/nixdeps.raw" > "$tmp/nixdeps.txt"

    # Old first, then new: py_source then describes the new tag with no restore.
    : > "$tmp/up.old"
    [[ -n "$old_ver" ]] && upstream_deps "$old_tag" "$tmp/up.old"
    upstream_deps "$new_tag" "$tmp/up.new"

    if [[ ! -s "$tmp/up.new" ]]; then
      # Distinguish "no metadata file" from "metadata file that declares nothing"
      # (conan, for instance, ships a 3-line pyproject.toml and keeps its
      # requirements in setup.py, which this does not read).
      if [[ -z "$py_source" ]]; then
        py_skipped="neither pyproject.toml nor requirements.txt exists at $new_tag"
      else
        py_skipped="upstream's $py_source at $new_tag declares no runtime dependencies, so there was nothing to compare (they may live in setup.py, which this does not read)"
      fi
    else
      norm < "$tmp/up.new" > "$tmp/up.new.n"
      py_missing=$(comm -23 "$tmp/up.new.n" "$tmp/nixdeps.txt" | paste -sd' ' -)
      if [[ -s "$tmp/up.old" ]]; then
        norm < "$tmp/up.old" > "$tmp/up.old.n"
        py_stale=$(comm -23 "$tmp/up.old.n" "$tmp/up.new.n" | comm -12 - "$tmp/nixdeps.txt" | paste -sd' ' -)
      fi
    fi
  fi
fi

# ---- write it out ---------------------------------------------------------
{
  echo "# #$pr $pr_title"
  echo
  echo "\`$attr\` · by $pr_author · rebuilds ${rebuilds:-unknown} · \`$pkg_path\`"
  [[ $pkg_nfiles -gt 1 ]] && echo "· note: the PR changes $pkg_nfiles nix files, these notes cover the first"
  changelog_urls "$tmp/body.md" 2 | sed 's/^/Changelog: /'
  echo
  echo "## What changed"
  echo
  [[ -n "$old_ver$new_ver" ]] && echo "- version \`$old_ver\` -> \`$new_ver\`"
  in_diff '^\+.*(hash|sha256|cargoHash|vendorHash|npmDepsHash) *=' && echo "- source hash updated"
  for a in "${ATTRS[@]}"; do
    [[ -n "${add[$a]}" ]] && echo "- \`$a\` added: ${add[$a]}"
    [[ -n "${rem[$a]}" ]] && echo "- \`$a\` removed: ${rem[$a]}"
  done
  in_diff '^\+.*__structuredAttrs' && echo "- \`__structuredAttrs = true\` added"
  $maint_changed && echo "- \`meta.maintainers\` changed"
  $license_changed && echo "- \`meta.license\` changed"
  in_diff '^\+.*(owner|repo|url|fetchFrom|fetchurl) *=' && echo "- source location touched"
  echo
  echo "## Watch out for"
  echo

  # Version shape.
  if [[ -n "$old_ver" && -n "$new_ver" && "$new_ver" != *unstable* && "${old_ver%%.*}" != "${new_ver%%.*}" ]]; then
    echo "- **Major version bump** ($old_ver -> $new_ver). Read the release notes for"
    echo "  breaking changes, new runtime dependencies and config-format changes."
  fi
  [[ "$new_ver" =~ (rc|alpha|beta|pre) ]] && echo "- Version looks like a pre-release; nixpkgs wants stable releases unless there is a reason."
  [[ "$new_ver" =~ ^0-unstable- ]] && echo "- Unstable version: the date must match the pinned rev's commit date."

  # Dependency edits.
  [[ -n "${add[dependencies]}" ]] && echo "- Dependencies were added. Confirm upstream actually requires them at runtime (see its metadata), rather than working around a build error."
  [[ -n "${rem[dependencies]}" ]] && echo "- Dependencies were removed. A green build does not prove a *runtime* dependency was unneeded; exercise the feature that used it."
  if [[ -n "${rem[pythonRelaxDeps]}" ]]; then
    echo "- \`pythonRelaxDeps\` entries were removed and the build passed. That establishes the"
    echo "  constraint is no longer a problem. It does NOT establish *why*, and the two possible"
    echo "  reasons call for different reviews: upstream loosened the constraint, or upstream"
    echo "  dropped the dependency entirely. Read upstream's dependency declaration at BOTH the"
    echo "  old and the new version before writing a word about the cause. If the dependency was"
    echo "  dropped, it should come out of \`dependencies\` too."
  fi
  [[ -n "${add[pythonRelaxDeps]}" ]] && echo "- \`pythonRelaxDeps\` entries were added. Relaxing a constraint hides a real incompatibility if upstream meant it; exercise the feature using that dependency."
  [[ -n "${add[build-system]}${rem[build-system]}" ]] && echo "- \`build-system\` changed. Check it against \`[build-system]\` in upstream's \`pyproject.toml\` at this tag."
  [[ -n "${add[patches]}" ]] && echo "- A patch was added. It needs a comment giving the upstream URL or why it is not upstreamed, and should be fetched rather than vendored."
  [[ -n "${rem[patches]}" ]] && echo "- A patch was removed. Confirm it was merged upstream and is not just being dropped because it stopped applying."

  # Missing runtime deps: the thing a green build cannot tell you.
  if [[ -n "$py_missing" ]]; then
    echo "- **Upstream declares runtime dependencies that nixpkgs does not**, per its $py_source at this tag:"
    echo "  \`$py_missing\`. A build and a \`pythonImportsCheck\` both pass without these;"
    echo "  they fail at runtime in whatever feature imports them. Names differ between"
    echo "  PyPI and nixpkgs, so check before reporting: \`$main -c 'import NAME'\`, or look"
    echo "  for the import in the source. This may well be pre-existing rather than the"
    echo "  PR's doing, which is worth saying if you raise it."
  fi
  if [[ -n "$py_stale" ]]; then
    echo "- **Upstream dropped a dependency that nixpkgs still carries**: \`$py_stale\`."
    echo "  It appears in upstream's $py_source at $old_ver and not at $new_ver, yet is still"
    echo "  in \`dependencies\`. Confirm with a grep over the new source for the import before"
    echo "  raising it — the name may differ, or it may be an undeclared-but-real dependency."
    echo "  If confirmed it is a non-blocking suggestion, not a request for changes."
  fi

  # Testing conditions.
  in_pkg 'doCheck *= *false' && echo "- \`doCheck = false\`: there is no automated functional check. Your hands-on run is the only one this PR gets."
  in_pkg 'makeDesktopItem|copyDesktopItems|wrapGAppsHook|tkinter|libsForQt|gtk[34]|qt[56]' && echo "- GUI application: launch it from a terminal inside your desktop session, not over a plain shell."
  in_pkg 'passthru.*tests|tests *=' && echo "- The package has \`passthru.tests\`; run them with \`nix-build -A $attr.tests\`."
  [[ "$pr_author" == r-ryantm ]] && echo "- Bot bump: the diff is mechanical, so the value you add is the changelog read and the hands-on run."
  $maint_changed && echo "- \`meta.maintainers\` changed. Someone adopting a package they use is normal and good; just confirm it is the PR author."
  $license_changed && echo "- \`meta.license\` changed: verify against the LICENSE file at the new tag."

  # What could NOT be checked. Silence here would read as "checked, clean",
  # which is exactly the confusion docs/before-you-post.md warns against.
  if [[ -n "$py_skipped" ]]; then
    echo "- **Not checked:** the upstream dependency comparison did not run — $py_skipped."
    echo "  Treat the absence of a dependency finding above as \"unknown\", not \"clean\"."
  fi
  echo
  echo "## Test plan"
  echo
  echo '```bash'
  echo "scripts/local-review.sh $pr"
  echo "# then, in the review shell:"
  echo "$bin/$main --version"
  echo "$bin/$main --help"
  echo "ls $bin/            # anything else shipped"
  # An import check needs an interpreter, not the package's entry point:
  # `thonny -c 'import wheel'` is not a runnable command.
  [[ -n "$py_missing" ]] && echo "python3 -c 'import ${py_missing%% *}'   # only meaningful inside the review shell's env"
  echo '```'
  echo
  echo "Do one real thing with it, not just \`--version\`: open a file, run a trivial"
  echo "job, list something. Note the exact commands; they go in the review comment."
  echo
  echo "Checklist: \`docs/review-checklist.md\` · Template: \`templates/review-comment.md\`"
  echo "Report: \`reports/$pr-gha.md\`"
  if [[ -f "$KIT/reports/$pr-triage.txt" ]]; then echo "Triage: \`reports/$pr-triage.txt\`"; fi
} > "$out"

[[ "$out" == /dev/stdout ]] || echo "$out"
