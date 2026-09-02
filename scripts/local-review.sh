#!/usr/bin/env bash
# Run nixpkgs-review locally from the nixpkgs checkout, inside the nixpkgs devshell.
#
# Usage: scripts/local-review.sh PR [nixpkgs-review args...]
#   scripts/local-review.sh 559184                             # build, then drop into the review shell
#   scripts/local-review.sh 559184 --no-shell --print-result   # unattended, report to stdout
#
# nixpkgs-review 3.x must run from inside a nixpkgs checkout; this script cd's there.
# nix-shell --command (not --run) keeps the shell interactive so the review shell works.
# NIXPKGS_DIR overrides the default checkout location, ~/Dev/nixpkgs.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

case "${1:-}" in '' | -h | --help) usage; exit 2 ;; esac
[[ $1 =~ ^[0-9]+$ ]] || die "PR must be a number, got: $1"
pr=$1; shift

cd "$NIXPKGS_DIR"
# Quote every argument so the inner shell does not re-split them.
printf -v cmd '%q ' nixpkgs-review pr "$pr" "$@"
exec nix-shell --command "$cmd"
