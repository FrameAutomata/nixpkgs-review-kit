# Verifying a finding before you write it down

A finding accuses a pull request, a package, or occasionally a person, in
public and under a real name. A false one costs a maintainer their time and
the reviewer their credibility, and it is worse than saying nothing at all.

These rules apply to anyone producing findings from this kit — you reading a
diff, or an assistant running commands on your behalf. Each one exists because
it was violated in practice and produced a plausible-looking finding that was
wrong. The examples are real.

## A. No behavioural claim without a baseline

Before writing that the new version behaves some way, run the identical command
against the previous version and record both results:

```bash
nix shell nixpkgs#<attr> -c <cmd>   # previous version, straight from the binary cache
```

No GC root, no local build. If the old version does the same thing, it is not
this PR's doing.

*Caught in practice:* `tpl -g 'fail, halt'` exiting 0 looked like a regression
on a major version bump. The 2.x line did it too.

## B. Rule out your own environment before blaming the package

Any failure under a sandbox, a container, or an unusual `HOME` is your setup
until proven otherwise. Re-run with the offending constraint dropped. If it then
passes, report the interaction, not a defect.

*Caught in practice:* `qbit-manage --version` died with
`PermissionError: '/nonexistent'` under `ProtectHome=yes`, because the program
creates its config directory at import time, before handling `--version`.

## C. Never read an exit status through a pipe

`cmd | tail` reports `tail`'s status, and `tail` almost always succeeds.

```bash
out=$(cmd 2>&1); st=$?          # right
cmd 2>&1 | tail -5; echo $?     # WRONG: that is tail's status
```

*Caught in practice:* a package was reported as "exits 0 despite a traceback"
when the 0 belonged to `tail`.

## D. A negative result needs proof the search ran

An empty grep is not evidence until you have shown it could have matched.
Confirm the tree extracted, then run a control search for a term that must be
present.

*Caught in practice:* `grep -rn 'import git'` over a source tarball returned
nothing, which would have meant nothing at all had the extraction silently
failed. The control grep for `qbittorrent` matched, so the empty result was
real.

## E. Separate the observation from the cause

"The build passed with the constraint removed" is an observation. "Upstream
loosened the constraint" is a causal claim needing its own evidence — and it may
be wrong in a way that changes the whole review.

*Caught in practice:* that exact inference was wrong. Upstream had dropped the
dependency entirely, which meant the correct review comment was a different one:
the dependency should also come out of `dependencies`.

## F. Every finding carries its command

If you cannot show the exact invocation and its verbatim output, the finding
does not go in.

## G. Assume you are wrong about the domain first

When a program does something surprising, the likeliest explanation is that you
do not yet know its conventions, not that it is broken. Check the documentation,
or compare against the previous version, before calling it a bug.

*Caught in practice:* `atom_codes(A,"xyz")` raising `type_error` looked like a
defect. Trealla's `double_quotes` flag defaults to `chars`, so the test was
wrong, not the package.

## H. Be fair about people

If a finding touches someone's conduct — a maintainer addition, an undisclosed
change, a missing acknowledgement — look for the innocent explanation first and
say what you found either way.

*Caught in practice:* a PR adding a third party to `meta.maintainers` looked
worth questioning until a check showed the two already co-maintain another
package together. The finding survived, but as a light question rather than
something implying impropriety.

## Findings that survive all of this are still candidates

Verification lowers the rate of confident errors. It does not eliminate them.
Whoever posts must reproduce a finding with their own commands before it goes
on a public PR under their name — see `docs/before-you-post.md`.
