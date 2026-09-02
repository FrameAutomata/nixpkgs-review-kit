# nixpkgs-review-gha reference

Upstream: <https://github.com/Defelo/nixpkgs-review-gha>. Your fork:
<https://github.com/FrameAutomata/nixpkgs-review-gha>. Details below were
checked against the upstream `review.yml` and README on 2026-09-02.

## What a run does

For the given PR number, one job per selected system:

1. Checks out nixpkgs, installs Nix and nixpkgs-review on the runner.
2. Runs `nixpkgs-review pr N --no-shell --no-exit-status --no-headers --print-result --build-args="-L ..."`
   plus anything from the `extra-args` input. Evaluation results come from
   nixpkgs' own CI, so no full local evaluation happens.
3. Uploads `report_<system>.json`. A final `report` job merges the per-system
   reports into one Markdown comment, posts it if `post-result` is true, and
   applies the `on-success` action.

Posting goes through the project's relay server and appears from the
`@nixpkgs-review-gha` account. No token on your side is required.

## Inputs

Set from the "Run workflow" dialog in the Actions tab, or with
`gh workflow run review.yml -R FrameAutomata/nixpkgs-review-gha -f name=value`.
`scripts/gha-review.sh` wraps the common cases.

| Input | Type | Default | Notes |
|---|---|---|---|
| `pr` | string | required | nixpkgs PR number |
| `x86_64-linux` | boolean | `true` | `ubuntu-latest` runner |
| `aarch64-linux` | boolean | `true` | `ubuntu-24.04-arm` runner |
| `x86_64-darwin` | choice | `yes_sandbox_relaxed` | `no`, `yes_sandbox_false`, `yes_sandbox_relaxed`, `yes_sandbox_true`; runs on `macos-latest` |
| `aarch64-darwin` | choice | `yes_sandbox_relaxed` | same options; runs on `macos-latest` |
| `riscv64-linux` | boolean | `false` | needs the RISE GitHub App installed on the fork |
| `builders` | choice | `gha` | `gha`, `remote`, `both`; `remote` needs the SSH secrets below |
| `extra-args` | string | empty | passed straight to nixpkgs-review, e.g. `--package foo`, `--skip-package bar`, `--systems x86_64-linux` |
| `push-to-cache` | boolean | `true` | no effect unless a cache is configured |
| `upterm` | boolean | `false` | open an SSH session on the runner after the review for interactive testing |
| `post-result` | boolean | `true` | the script sets this to `false` unless you pass `--post` |
| (darwin inputs) | | | the script sets both darwin inputs to `no` unless you pass `--darwin` |
| `on-success` | choice | `nothing` | `nothing`, `mark_as_ready`, `approve`, `merge`; keep `nothing` |

## Runner limits

| Runner | vCPU | RAM | Disk |
|---|---|---|---|
| Linux x64 and arm64 | 4 | 16 GB | 14 GB |
| macOS arm64 | 3 | 7 GB | 14 GB |

- Standard runners are free and unlimited for public repositories.
- A job is killed after six hours.
- Free plan: 20 concurrent jobs, at most 5 on macOS. A full four-system run
  uses four slots plus the report job.
- 14 GB of disk rules out large builds. Skip PRs with the 101+ or 501+
  rebuild labels, and packages like Chromium, LLVM or LibreOffice.

## Optional configuration on the fork

All are repository secrets or variables under Settings, Secrets and variables, Actions.

| Name | Kind | Purpose |
|---|---|---|
| `GH_SELF_UPDATE_TOKEN` | secret | fine-grained PAT for the `self-update` workflow (recommended) |
| `GH_TOKEN` | secret | classic PAT with `public_repo`; only needed for `mark_as_ready`/`merge`. Not recommended, see README |
| `API_URL` | variable | use your own relay server instead of the default |
| `CACHIX_CACHE`, `CACHIX_AUTH_TOKEN`, `CACHIX_SIGNING_KEY` | variable, secret, secret | push built packages to a Cachix cache so you can pull them locally |
| `ATTIC_SERVER`, `ATTIC_CACHE`, `ATTIC_TOKEN` | variable, variable, secret | same for an Attic cache; takes precedence over Cachix |
| `EXTRA_NIX_CONFIG` | variable | appended to `nix.conf` on the runner, e.g. extra substituters |
| `SSH_KEY`, `SSH_CERT`, `BUILDERS` | secret, secret, variable | remote builders, for example the nix-community builders |
| `IDENTIFY_STILL_FAILING_PACKAGES` | variable | set to `1` to re-try failures on the base branch and mark them "still failing". **Set on this fork since 2026-09-02.** |
| `IDENTIFY_UNSUPPORTED_PACKAGES` | variable | on by default; marks failures caused by missing runner features (like `kvm`) as "unsupported" |

## Reading the report

- One collapsible section per system listing built, failed, and unsupported
  packages, with log snippets for failures.
- "unsupported" means the runner cannot build it (usually NixOS tests needing
  KVM). Not the PR's fault.
- "still failing" means it also fails on the base branch. Worth a note on the
  PR, not a blocker. The reverse is weaker: the base "rebuild" is a normal
  `nix build`, so when Hydra has already cached that package the runner just
  downloads it and learns nothing. A package that fails only in the PR build
  while Hydra builds it fine is either the PR or the runner environment.
- Full logs: open the run in the Actions tab, expand the job for that system.

## Useful commands

```bash
# Start runs (Linux only by default; pre-flight skips merged/approved/conflicted PRs)
scripts/gha-review.sh N1 N2 N3
scripts/gha-review.sh --darwin --post N
scripts/gha-review.sh --extra-args "--package foo" N

# Explain failures from every report available for a PR
scripts/triage-failures.sh N

# List and inspect runs
gh run list  -R FrameAutomata/nixpkgs-review-gha --workflow review.yml --limit 10
gh run watch -R FrameAutomata/nixpkgs-review-gha <run-id>
gh run view  -R FrameAutomata/nixpkgs-review-gha <run-id> --log-failed

# Cancel a run that turned out to be huge
gh run cancel -R FrameAutomata/nixpkgs-review-gha <run-id>

# Get the merged report of the newest finished run without posting it:
# triage saves it to reports/<pr>-gha.md. (The report.md artifact is plain
# Markdown, so `gh run download` rejects it; the helper goes through the API.)
scripts/triage-failures.sh <pr>
```
