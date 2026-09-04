# Before you post a review

`docs/review-checklist.md` covers *what to check about a PR*. This covers a
different question: **which of those checks must you do personally, and which
can you take from the tooling?**

You post under your own name. A maintainer reads it and spends their time on
the strength of it. So the rule is one sentence:

> Every ticked box and every sentence in the comment must be something you
> can personally defend if asked "how do you know?"

That is not the same as doing everything by hand. Some evidence is public and
checkable by anyone; some only exists if you did it.

## You can take these from the tooling

Because the evidence is objective and linked in the comment, so a reader can
check it themselves:

- **The build result.** The Actions run is public and you link it. Ticking
  "package builds on x86_64-linux" cites that run; it does not claim you
  compiled it yourself.
- **"All depending packages build"**, when the report shows the package is a
  leaf and lists no failures. Read the report, do not just trust the tick.
- **Mechanical facts about the diff**: version string format, attribute name,
  whether the package has patches. These are visible in `gh pr diff` in
  seconds — glance at it rather than taking the script's word.

`scripts/review.sh` ticks exactly these and annotates each with its evidence.

## Only you can do these

No script and no assistant can produce these on your behalf:

- **Running the binary.** If "executables tested" is ticked, you ran something.
  Output pasted into a chat by someone else, or produced by an assistant in a
  sandbox, is not you having tested it. This is the box most likely to get
  ticked wrongly, because it is the one that takes real effort.
- **Reading the changelog.** "Any change of upstream are verified" means you
  read what changed between the two versions and nothing alarmed you.
- **Reading the diff.** Not the summary of the diff. The diff.

## The two-minute pass, right before you post

1. **Read your own comment top to bottom as if you were the maintainer.** For
   every tick, answer "how do I know?" out loud. If the answer is "the tool
   said so" for anything in the "only you" list, untick it.
2. **Check the output you pasted for error lines.** An `ERROR:` or a traceback
   in the middle of otherwise-normal output is easy to skim past, and pasting a
   failed command as evidence of success is the worst way to be wrong.
3. **Check nobody got there first**:
   `gh pr view N -R NixOS/nixpkgs --json state,reviewDecision`
4. **Check for AI-authored wording.** Research and testing help is exempt from
   the nixpkgs automation/AI policy. Text in the comment is not. If a sentence
   is not yours, rewrite it or disclose it.

## If you are reporting a finding

A finding accuses the PR, the package, or occasionally a person, in public, so
it carries a higher bar than the rest of the review. The rules for clearing that
bar — baseline against the previous version, rule out your own environment and
your own misunderstanding, separate what you saw from why you think it happened,
be fair about people — are in **`docs/verifying-findings.md`**, with the real
cases that produced each one.

One thing from there bears repeating here, because it is what a reviewer skips
when in a hurry: **reproduce it with your own commands** before writing it down.
A finding handed to you by a tool or an assistant is a candidate, not a
conclusion.

## It is fine to post less

A smaller honest review beats a larger one you cannot defend. All of these are
legitimate contributions:

- The build report alone, with no hands-on testing claimed. Use `--comment`
  rather than `--approve` and leave "executables tested" unticked.
- A comment noting one specific thing you checked and nothing else.
- Nothing at all, if you looked and have nothing to add.

The failure mode that hurts the project is not a modest review. It is a
thorough-looking review that nobody actually performed.
