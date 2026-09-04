# Local review on this machine

Use this to run the binaries yourself, or to build something the hosted
runners cannot. The machine has 8 cores, 15 GB RAM and plenty of disk.

## Running

```bash
scripts/local-review.sh N                          # build, then open the review shell
scripts/local-review.sh N --no-shell --print-result   # unattended, report on stdout
```

The script changes into `~/Dev/nixpkgs`, enters nixpkgs' devshell, and runs
`nixpkgs-review pr N`. Equivalent by hand:

```bash
cd ~/Dev/nixpkgs
nix-shell
nixpkgs-review pr N
```

Inside the review shell:

- `./results/<pkg>-<system>/bin/` holds the built outputs.
- `nixpkgs-review post-result` posts the report under your own account.
- `nixpkgs-review approve` approves the PR. Only after the checklist is done.
- `exit` leaves the shell; the worktree is removed automatically.

Other subcommands: `nixpkgs-review wip` builds your uncommitted changes in the
checkout, `nixpkgs-review rev HEAD` builds the last commit.

## Where things live

- Per-PR work dir: `~/.cache/nixpkgs-review/pr-N/` with `report.md`,
  `report.json`, `logs/`, `results/`. Safe to delete when done.
- Git worktrees are created under that directory and pruned on exit. If a
  run was interrupted, `git -C ~/Dev/nixpkgs worktree prune` cleans up.
- Fetched PR refs are stored in the checkout as `refs/nixpkgs-review/*`.

## Gotchas found on 2026-09-02

- nixpkgs-review 3.x must run from inside a nixpkgs checkout. Outside it,
  it exits with "Has to be executed from nixpkgs repository".
- The GitHub token is taken from `gh auth token`. Without it, nixpkgs-review
  falls back to evaluating all of nixpkgs locally, which needs many gigabytes
  of RAM. If you see "Falling back to local evaluation", stop and run
  `gh auth status`.
- The warning "ignoring the client-specified setting 'sandbox'" appears because
  this user is not in `trusted-users`. The system sandbox is on anyway; only
  packages that need a relaxed sandbox are affected. Add yourself to
  `nix.settings.trusted-users` in the NixOS config if that ever matters.
- Only `cache.nixos.org` is configured as a substituter, so dependencies not
  yet on Hydra get built locally. PRs against `staging` can mean a lot of
  building; prefer the Actions run or skip them.
- A first run needs a few hundred megabytes of downloads; the spec-kit trial
  took about three minutes end to end.
