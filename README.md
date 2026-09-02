# nixpkgs package review kit

Instructions and helpers for testing and reviewing nixpkgs pull requests.
Builds run in GitHub Actions through a personal fork of
[nixpkgs-review-gha](https://github.com/Defelo/nixpkgs-review-gha), which runs
[nixpkgs-review](https://github.com/Mic92/nixpkgs-review) on hosted runners for
x86_64-linux, aarch64-linux, x86_64-darwin and aarch64-darwin. Hands-on testing
of the built binaries happens on this machine with a local nixpkgs checkout.

The documents and scripts here were drafted with AI assistance (Claude) and
reviewed by the repository owner. Anything from this kit that ends up in a
contribution to nixpkgs or related projects must carry the disclosure that
project's automation policy requires.

## Layout

| Path | Purpose |
|---|---|
| `README.md` | Setup and the day-to-day workflow (this file) |
| `docs/review-checklist.md` | What to check for package updates and new packages |
| `docs/nixpkgs-review-gha.md` | Reference for the Actions workflow: inputs, limits, how results are posted |
| `docs/local-review.md` | Running nixpkgs-review on this machine |
| `templates/review-comment.md` | Template for the review comment |
| `scripts/lib.sh` | Shared config and helpers sourced by the scripts (fork name, PR metadata, report parsing) |
| `scripts/find-prs.sh` | List candidate PRs |
| `scripts/gha-review.sh` | Start an Actions review for one or more PRs |
| `scripts/local-review.sh` | Run nixpkgs-review locally from the nixpkgs checkout |
| `scripts/triage-failures.sh` | Explain failed packages: still-failing marker, Hydra status, open issues |
| `reports/` | Scratch space for saved reports (git-ignored) |

## Prerequisites

Already in place on this machine as of 2026-09-02:

- `gh` logged in as FrameAutomata (`gh auth status`).
- nixpkgs checkout at `~/Dev/nixpkgs` with the `upstream` remote pointing at NixOS/nixpkgs.
- nixpkgs' own devshell (`nix-shell` inside `~/Dev/nixpkgs`) provides nixpkgs-review 3.9, gh and nix-eval-jobs.

## One-time setup

1. **Fork the workflow repo** (keep the default name so the scripts and the browser shortcut work):

   ```bash
   gh repo fork Defelo/nixpkgs-review-gha --clone=false
   ```

2. **Enable workflows on the fork.** GitHub disables Actions on forks until you
   opt in. Open <https://github.com/FrameAutomata/nixpkgs-review-gha/actions>
   and click "I understand my workflows, go ahead and enable them".

3. **Enable self-updates** (recommended, keeps the fork in sync with upstream).
   GitHub ships scheduled workflows on forks in a disabled state and hides
   disabled workflows from the Actions sidebar, so `self-update` will not be
   visible there. Set the secret first, then enable it from the CLI; the
   workflow disables itself again if it runs without the secret.
   - Create a fine-grained personal access token at
     <https://github.com/settings/personal-access-tokens> restricted to the
     fork only, with "Contents" and "Workflows" set to read and write.
   - Store it on the fork, enable the workflow, and run it once to confirm.
     Use the file name, not the display name: gh cannot look up a
     `disabled_fork` workflow by name and reports "could not find any
     workflows named self-update".

     ```bash
     gh secret set GH_SELF_UPDATE_TOKEN -R FrameAutomata/nixpkgs-review-gha
     gh workflow enable self-update.yml -R FrameAutomata/nixpkgs-review-gha
     gh workflow run self-update.yml -R FrameAutomata/nixpkgs-review-gha
     gh workflow list -R FrameAutomata/nixpkgs-review-gha --all   # self-update should be "active"
     ```

   Leave `flake-update` disabled; it is upstream's own dependency-bump job.

4. **Do not add a `GH_TOKEN` secret.** Reports are posted through the
   project's relay server under the `@nixpkgs-review-gha` account with no
   configuration. A classic token with `public_repo` scope would grant write
   access to every public repository you can touch, and the upstream README
   advises against it.

5. **Smoke test** on a small PR without posting anything:

   ```bash
   scripts/gha-review.sh --watch 559184
   ```

   Optional: install `shortcut.user.js` from the fork as a browser userscript
   to get a "Run nixpkgs-review" button on nixpkgs PR pages.

## Daily workflow

Most of the time goes into builds, so the loop is built around not building
what you do not have to.

1. **Pick a PR.** `scripts/find-prs.sh` lists open package updates with
   exactly one rebuild (leaf packages), no reviewer on them yet, and shows
   whether the update bot's own build report in the PR body passed. Leaf runs
   finish in a couple of minutes. Widen with `--tier 1-10` when you want
   packages that have dependents, and prefer packages you use or maintain.

2. **Read before building.** For r-ryantm PRs the body already contains an
   x86_64-linux nixpkgs-review result. If it lists failures, run
   `scripts/triage-failures.sh N` first; most are pre-existing and you may
   not need a build of your own at all. Then the diff and the checklist:

   ```bash
   gh pr view N -R NixOS/nixpkgs
   gh pr diff N -R NixOS/nixpkgs
   ```

   If something is wrong at this stage, say so on the PR and stop.

3. **Start the build check, in batches.** Linux only by default, no posting.
   Pre-flight skips PRs that were merged, approved, or conflicted since you
   listed them, and warns about big rebuild counts:

   ```bash
   scripts/gha-review.sh N1 N2 N3        # fire several, read diffs while they build
   scripts/gha-review.sh --darwin N      # add both macOS runners when darwin matters
   scripts/gha-review.sh --post N        # post the report to the PR when done
   ```

   Hydra already builds darwin, so only ask for it when the package is
   darwin-relevant. Each system builds in parallel; five macOS jobs at a time.

4. **If the report lists failures**, explain them before doing anything else:

   ```bash
   scripts/triage-failures.sh N
   ```

   It reads every report available for the PR (bot report in the body, local
   run, the fork's latest run), and for each failed package prints whether the
   workflow already marked it still failing on the base branch, what Hydra
   says on master, open issues with it in the title, and a base-build command
   to confirm. Only failures Hydra builds fine on master need real attention.

5. **Test the binaries locally.** The Actions run proves the build; it cannot
   run the program for you:

   ```bash
   scripts/local-review.sh N
   ```

   This builds the changed packages for x86_64-linux and drops you into a
   shell where `./results/<pkg>/bin/` holds the outputs. Run the main
   program, check `--version`, do a small real task with it. Exit when done.
   Details in `docs/local-review.md`.

6. **Write the review.** Start from `templates/review-comment.md`, keep only
   the points you actually checked, mention how you triaged any failures.
   Check the PR is still open and unreviewed, then comment or approve:

   ```bash
   gh pr view N -R NixOS/nixpkgs --json state,reviewDecision
   gh pr review N -R NixOS/nixpkgs --comment --body-file reports/N-review.md
   gh pr review N -R NixOS/nixpkgs --approve --body-file reports/N-review.md
   ```

   Merging is done by committers or, for r-ryantm bumps of `pkgs/by-name`
   packages you maintain, by commenting `/nixpkgs-merge-bot merge`.
   Becoming a maintainer of packages you use is the one change that turns
   your reviews into merges instead of adding to the approved-but-unmerged pile.

## Rules

- **Posting is deliberate.** The script defaults to not posting. Posting the
  build report is normal and expected in nixpkgs, but it carries your name, so
  only post on PRs you have actually looked at.
- **No automated approvals or merges.** The script pins `on-success=nothing`.
  A green build is one checklist item, not a review.
- **Automation and AI policy.** nixpkgs requires a responsible person in the
  loop and disclosure of non-trivial automation in any contribution, including
  review comments (`CONTRIBUTING.md`, "Automation/AI policy"). Running
  nixpkgs-review is standard tooling and the report identifies itself. Using
  an AI assistant for research, testing or private review is exempt. If AI
  output ends up in the text of a review comment, disclose it in that comment,
  and never post text you have not read and understood.
- **Mind the runner limits.** Hosted runners have 4 vCPUs, 16 GB RAM (7 GB on
  macOS arm64), 14 GB disk and a six-hour job limit. Pre-flight refuses PRs
  labelled 101+ rebuilds; anything like Chromium or LLVM does not fit either.
  Use `--extra-args "--package foo"` to narrow a run when needed.

## Troubleshooting

- `self-update` (or any workflow) is missing from the Actions sidebar: GitHub
  hides disabled workflows. `gh workflow list -R FrameAutomata/nixpkgs-review-gha --all`
  shows every workflow with its state. To enable one in `disabled_fork` state,
  pass the file name (`gh workflow enable self-update.yml`) or the numeric ID;
  the display name only works for active or manually disabled workflows.
- `gh workflow run` fails with 404 or "workflow not found": the fork does not
  exist yet, or workflows were never enabled on it (setup steps 1 and 2).
- macOS jobs fail on sandbox errors: rerun with the darwin inputs set to
  `yes_sandbox_false` from the Actions UI, or leave darwin off (the default) if Linux is
  what matters for that package.
- Report marks packages "unsupported": the runner lacks a system feature such
  as `kvm` (typical for NixOS tests). That is not a failure caused by the PR.
- Local run says "Has to be executed from nixpkgs repository": nixpkgs-review
  3.x must run inside the checkout. Use `scripts/local-review.sh`.
- Local run says "Falling back to local evaluation": the GitHub token was not
  found, check `gh auth status`. Local evaluation needs many gigabytes of RAM;
  stop the run and fix the token instead.
