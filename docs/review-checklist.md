# Review checklist

Adapted from `pkgs/README.md` ("Reviewing contributions") and the PR template
in nixpkgs. Work through the relevant section before starting builds, then
again after the builds and local testing.

## Package updates

Most PRs, including every r-ryantm bump. The diff is usually a version string
and a hash, sometimes a lock-file hash (`cargoHash`, `vendorHash`, `npmDepsHash`).

Before building:

- [ ] The new version exists upstream and is a release, not a pre-release or
      a moved tag. Check the upstream tags or releases page.
- [ ] Read the upstream changelog. Note breaking changes, new runtime
      dependencies, new build requirements, or a licence change.
- [ ] Only the expected fields changed. Extra edits (new patches, disabled
      tests, removed dependencies) need a reason in the PR or a code comment.
- [ ] Version fits the nixpkgs versioning rules (no `v` prefix, unstable
      versions dated).
- [ ] Commit message follows `attr: old -> new` and the PR body links the
      changelog or release notes.
- [ ] `meta.license` still matches upstream. `meta.maintainers` is not empty.
- [ ] Source location unchanged. If the fetcher, repo or mirror changed,
      confirm the new location is official.
- [ ] Patches carry a comment with the upstream URL or the reason they are
      not upstreamed, and are fetched rather than vendored when available.
- [ ] Any pin, disabled check, `substituteInPlace` or unusual build flag has
      a comment explaining why.
- [ ] No typos in the changed lines.

After building:

- [ ] Package builds on x86_64-linux and any other platform the report shows.
- [ ] All dependent packages in the report build. A dependent failing that
      already fails on master is worth mentioning but is not this PR's fault.
      `scripts/triage-failures.sh N` does the first pass automatically. By hand:
      the report marks "still failing" packages
      (rebuilt on the base branch by the workflow); check Hydra's latest
      build, failed ones included, with
      `curl -sH "Accept: application/json" "https://hydra.nixos.org/api/latestbuilds?nr=1&project=nixpkgs&jobset=unstable&job=<attr>.<system>"`
      (`buildstatus` 0 is success; the per-job "latest" page only ever shows
      successful builds, so do not use that); search open issues for the package;
      or build it locally on the base commit with
      `nix-build https://github.com/NixOS/nixpkgs/archive/<base-sha>.tar.gz -A <attr>`.
      Say which of these you did in the review comment.
- [ ] Executables tested on x86_64-linux (see "Testing binaries").
- [ ] `passthru.tests` or NixOS tests ran if the package has them.

## New packages

- [ ] File is at `pkgs/by-name/<xx>/<name>/package.nix` and the name follows
      the naming rules (lowercase, dashes, no version in the attribute).
- [ ] Version fits the versioning rules.
- [ ] Commit message is `<attr>: init at <version>`.
- [ ] Source comes from an official location or a trusted mirror, using the
      right fetcher (`fetchFromGitHub` for GitHub, `mirror://` when available).
- [ ] `meta.description` is short, capitalised, no trailing period, no package name.
- [ ] `meta.homepage`, `meta.license`, `meta.platforms`, `meta.maintainers` set.
- [ ] `meta.mainProgram` set when there is a main executable.
- [ ] Build-time-only dependencies are in `nativeBuildInputs`.
- [ ] `phases` is not overridden. Overridden phases start with
      `runHook pre<Phase>` and end with `runHook post<Phase>`.
- [ ] Patches documented and fetched rather than vendored.
- [ ] `passthru.updateScript` present where an updater applies; a version
      test (`testers.testVersion`) or another `passthru.tests` entry is a plus.
- [ ] Package builds and executables tested.

## Testing binaries

Do this on the machine, not in Actions. After `scripts/local-review.sh N`
you are in a shell where `./results/<pkg>/bin/` holds the outputs.

- Run the main program with `--version` and `--help`.
- Do one real thing with it: open a file, run a trivial job, list something.
- For libraries, build one dependent from the report and run that instead.
- For services, check the binary starts and reads its config; a full NixOS
  test is only needed when the PR touches a module.
- Note the exact commands you ran; they go in the review comment.

## What to write

Use `templates/review-comment.md`. Only tick what you did. State the platform
you tested on. Mention anything you noticed that is not blocking under
"Possible improvements" rather than as a request for changes. If you request
changes, use GitHub's "Request changes" review type so it is clearly blocking,
and stay available for the follow-up.
