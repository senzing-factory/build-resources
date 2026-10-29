#!/usr/bin/env python3
"""Turn the reviewer's structured findings into the comment body.

    review_output.py --findings <file> --manifest <file> --base <rev>
                     --out <file> [--sections <file>] [--notes <file>]
                     [--previous <file>] [--metrics <file>]
                     [--head <sha>] [--lane <A|B|C|S>]
                     [--coverage-read N] [--coverage-total N]
                     [--summary <text>] [--restored "<paths>"]

`--findings` names a JSON file holding `{"findings": [ ... ]}`, written by
review_text.py from the `structured_output` of the CLI's terminal `result`
event. Every object in it has already been validated against
`claude/review-schema.json` by the CLI, which refuses the model's tool call
and makes it try again until the object conforms.

WHAT THIS IS FOR: four measured complaints about this reviewer, none of which
a prompt instruction fixed on its own -- tick lines against criteria needing
no action (29 then 32 in two consecutive reviews of one pull request); the
reviewer reporting its own blindness as a finding (13 such phrases per review
in that same pair); criteria that do not apply to the repository (a CHANGELOG
demanded in 38.4% of 4,932 fleet reviews, including in 17 repositories that
have never had one); and a run longer than the last while reporting fewer
real findings, which is a comparison and so needs something to keep the
previous number.

A PROMPT CANNOT ENFORCE ANY OF THESE, because the model writes the output and
the model is what produces the filler. So the mechanisms live here, and each
is a rejection with a count rather than a request:

  1. NO OUTPUT TEMPLATE. A one-line header and the findings; a further
     section exists only if something populated it.
  2. A FINDING ASSERTING A MISSING ARTEFACT MUST CITE A PATH THAT EXISTS AT
     THE BASE REF -- see CONVENTION, and its scoping.
  3. BLINDNESS IS NOT A VERDICT. It becomes a coverage status with a reason
     code from the manifest row -- see BLINDNESS, and whose blindness counts.
  4. AN UNRESOLVABLE ANCHOR IS DOWNGRADED, NEVER PROMOTED -- see
     `anchor_verdict`. A different subject from 2, and they must not overlap.
  5. THE HEADER IS RECOMPUTED, NOT COPIED, and recomputed again after every
     trim -- see `assemble`. Computed once, it said "5 findings -- 5
     blockers" over a comment carrying four.
  6. NO STRUCTURED OUTPUT IS NOT A CLEAN VERDICT. `{"findings": []}` is the
     clean verdict and says so unambiguously, because the model had to
     produce it. A run that produced no object at all adjudicated nothing,
     which is a different thing -- see `load`.
  7. A DROP IS DISCLOSED ON THE PULL REQUEST, not only in the job log -- see
     `drop_section`. A sole finding dropped by 2 or 3 used to post as "No
     blocking findings."
  8. THE CLEAN LINE CARRIES ITS OWN DENOMINATOR -- see `coverage_note`.
  9. THE SAME FINDING TWICE IS ONE FINDING -- see `collapse`, which is all
     that is left of a 185-line module.
 10. A FINDING THAT DISCLAIMS ITSELF IS PADDING -- see SELF_DISCLAIM.
 11. AN ANCHOR THAT CANNOT BE CHECKED IS NOT ONE THAT FAILED -- `--restored`.
 12. THE MODEL MAY NOT WRITE THE COMMENT'S STRUCTURE. A message and a path
     are rendered into a markdown bullet and an inline code span, and the
     body carries a state marker that later runs parse. Text that can forge
     any of those is collapsed or refused -- see `build_verdict`, and
     `previous_stats`, which reads the LAST marker for the same reason.
 13. THE COMMIT UNDER REVIEW IS RENDERED, NOT ONLY MARKED -- see `anchor`.
     The comment is edited in place, and GitHub renders an edited comment
     at its original creation time, so the only thing tying a review to a
     commit was an invisible HTML comment.
 14. A DISAGREEMENT BETWEEN TWO PIECES OF PROSE IS NOT A FINDING -- see
     PROSE_ONLY. Nothing it describes can change behaviour, so unlike
     every other rejection it is NOT disclosed on the pull request: a
     review whose only finding was one of these renders the ordinary
     clean verdict. It stays in the job log, in the metrics and in the
     marker -- see DISCLOSED, which is the one exception to 7.

WHAT THE SCHEMA TOOK OVER. Every mechanism above used to sit downstream of a
markdown parser: a bullet regex, a loose variant, a third for the malformed
case, a salvage path that truncated what it could not fit, and an anchor
splitter recovering a path and a line from one backticked string. Five
consecutive cold reviews each found a real defect and every one was in that
layer. None of it exists now: the severity is an enum the CLI enforces, the
path and the line are separate typed fields, and output that does not conform
never becomes a finding object at all. What stayed are the three rules that
read ENGLISH -- BLINDNESS, CONVENTION, SELF_DISCLAIM -- because a schema says
what shape a finding has, not whether its sentence is a finding.

`load` validates the shape a second time anyway and counts what it rejects.
Not because the CLI's validation is in doubt, but because it is the second
witness: if the two ever disagree, a number says so on the pull request
instead of findings quietly ceasing to appear.

WHAT IT DELIBERATELY DOES NOT DO. It does not rewrite a finding's prose, it
does not shorten one, and it does not judge whether a finding is correct.
Every mechanism above is a drop, a downgrade or a recount, each visible in
the metrics.

THE PRIVATE SCRATCHPAD. `--notes` names the file the `review-note` wrapper
appends to; this program prints it to the job log and never to the comment.
The impulse to report a clean check is given somewhere to go that is not a
pull request.

METRICS are written as `KEY=value` lines for `$GITHUB_ENV`, and every value
is a NUMBER. A path or a message there is author-controlled text one newline
away from appending arbitrary variables to the job environment, so no string
crosses into it; the paths the comment needs reach it through the sections
file instead.
"""

# pylint: disable=too-many-lines

import json
import os
import re
import subprocess
import sys
import time
from typing import NamedTuple

import review_io

USAGE = (
    "usage: review_output.py --findings <file> --manifest <file> --base <rev>\n"
    "                        --out <file> [--sections <file>] [--notes <file>]\n"
    "                        [--previous <file>] [--metrics <file>]\n"
    "                        [--head <sha>] [--lane <A|B|C|S>]\n"
    "                        [--coverage-read N] [--coverage-total N]\n"
    '                        [--summary <text>] [--restored "<paths>"]'
)

# The severities the schema declares. Re-stated rather than imported so this
# program is the second witness to the CLI's enum rather than a consumer of
# the same assertion.
SEVERITIES = ("BLOCKER", "RISK")

# What the reviewer says it could not do.
BLIND_VERBS = r"(?:see|confirm|verify|determine|assess|review|read|open|tell)"

# What the reviewer was GIVEN, as opposed to anything the code touches. Every
# one of these nouns names the review's own window on the repository, which
# is what makes it the second signal the subject-less clause below needs.
VIEW = r"(?:diff|patch|excerpt|chunk|section|context|snippet|review|manifest)"

# A finding that is really a coverage status. Each of these is the reviewer
# describing its own view rather than the code, which is a fact about the
# run and belongs in the coverage report with a reason code.
#
# THE SUBJECT HAS TO BE THE REVIEWER. A bare `cannot verify` matched "the
# caller cannot verify the signature" and a bare `not visible` matched "the
# error is not visible to the caller" -- real findings, removed from the
# comment and recorded as coverage statuses. The prompt's own definition of
# RISK is "plausible breakage you could not confirm from the tree", which
# steers the model into exactly that vocabulary, so the narrowing is
# load-bearing rather than tidy. First person, or the start of a clause
# where the reviewer is the implied subject, is the discriminator.
#
# AND A SUBJECT-LESS CLAUSE IS NOT ENOUGH ON ITS OWN. "Cannot read the
# manifest when XDG_CONFIG_HOME is unset" is a defect in the loader reported
# symptom-first, and the clause-start alternative was the hole the first
# person narrowing above left: it matched that sentence and dropped it.
# So the clause needs a second signal -- it names the reviewer's VIEW, or it
# ends right there, because "cannot confirm." with no object is a statement
# about the review and nobody's symptom. What that costs is the middle case,
# "cannot confirm the signature is checked" with no first person and no view
# noun: it now posts as a finding instead of being recorded as coverage.
# Deliberate. This branch DROPS, so a wrong match deletes a real finding
# silently while a missed one is merely filler on the pull request.
BLINDNESS = re.compile(
    r"(?:"
    rf"(?:^|[.;:,] )(?:cannot|can ?not|could not|unable to) {BLIND_VERBS}"
    rf"(?:[^.;:!?]{{0,60}}?\b(?:from|in|within|without|outside) "
    rf"(?:the |this |my |any )?{VIEW}\b|[\s.!?]*$)"
    r"|\b(?:i|we) (?:cannot|can ?not|could not|could ?n.t|ca ?n.t"
    rf"|(?:am|are|was|were) unable to) {BLIND_VERBS}"
    rf"|not visible in (?:the |this |my )?{VIEW}"
    r"|no patch (?:was )?(?:supplied|available|provided)"
    r"|in this (?:part|chunk|section) (?:of|only)"
    r"|not (?:included|supplied) in (?:the|this) (?:diff|patch|review)"
    r"|was not (?:reviewed|examined|opened|read)"
    r"|outside (?:the|this) (?:diff|patch|excerpt)"
    r"|truncated(?: patch| diff)"
    r")",
    re.IGNORECASE,
)

# The artefacts the padding measurement was actually about: a CHANGELOG
# entry, a README line, documentation, a test. Everything in CONVENTION is
# scoped to one of these.
ARTEFACT = (
    r"(?:changelog|change log|readme|entry|documentation|docs?"
    r"|tests?|test case|test coverage|license|licence)"
)

# A finding that asserts an absent ARTEFACT. Narrow on purpose: it must read
# as "this thing is missing", not merely mention a filename. "Missing error
# handling in src/x.go" cites a path that exists and therefore passes -- the
# gate is the citation, not the wording, and the wording only decides whether
# the gate applies.
#
# SCOPED TO THE NOUNS, because the drop is outright while mechanism 4 only
# downgrades. A bare `\bmissing\b` or `\bhas no\b` made the two overlap on
# any finding whose citation did not resolve: "the handler has no timeout"
# was dropped with no record, while "the handler lacks a timeout" at the same
# unresolvable path was downgraded to a RISK and posted. Two findings one
# word apart, opposite treatment.
CONVENTION = re.compile(
    r"(?:"
    rf"\bmissing (?:an? |the )?{ARTEFACT}\b"
    rf"|\b{ARTEFACT} (?:is |was )?(?:missing|absent)\b"
    # PREDICATIVE ONLY. "undocumented" is a claim about absent documentation
    # when it is what something IS -- "the `--lane` flag is undocumented" --
    # and a claim about a dependency when it MODIFIES a noun: "relies on an
    # undocumented ordering guarantee" is a risk about the thing depended on,
    # and the bare word dropped it outright. The artefact scoping the rest of
    # this pattern uses cannot be applied here, because the artefact this
    # alternative is about is the word itself; the copula is the discriminator
    # instead. "an undocumented flag" now survives, which is filler getting
    # through rather than a finding being deleted.
    r"|\b(?:is|are|was|were|remains?|stays?|left) "
    r"(?:still |currently )?undocumented\b"
    r"|\bnot documented\b"
    rf"|\bno {ARTEFACT}\b"
    rf"|\bhas no {ARTEFACT}\b"
    # `should be updated` was the one alternative with no ARTEFACT in it, so
    # "the timeout should be updated to 30s" was dropped outright -- a real
    # finding deleted under a reason that named a citation it never made.
    rf"|\bshould (?:be )?(?:add|added|update|updated|include|included)"
    rf" (?:an? |the )?{ARTEFACT}\b"
    rf"|\b{ARTEFACT} should (?:be )?(?:add|added|update|updated"
    r"|document|documented|include|included)\b"
    # Same treatment, by the lookahead SELF_DISCLAIM already uses for the
    # same reason: the whole finding is dropped, so one documentation clause
    # riding along with substance deletes the substance too. "The workflow
    # grants `contents: write`; the reason should be documented and the scope
    # narrowed" is a security finding that this alternative ate. It counts
    # where the sentence ends there, or where it names the artefact it wants
    # the line added to.
    rf"|\bshould (?:be )?document(?:ed)?"
    rf"(?= (?:in|on|under|within) (?:an? |the )?{ARTEFACT}\b|[\s.!]*$)"
    rf"|\bneeds? (?:an? )?{ARTEFACT}"
    rf"|\bwithout (?:an? )?{ARTEFACT}"
    rf"|\b{ARTEFACT} (?:was |is |has )?not (?:updated|bumped|added)\b"
    rf"|\bnot (?:updated|bumped|added) (?:in |for )?(?:the )?{ARTEFACT}\b"
    r")",
    re.IGNORECASE,
)

# Mechanism 10. A finding whose own text says there is nothing to report.
# The #340 shape was a blocking item reading "The PR does not touch
# .claude/CLAUDE.md, so there is nothing to flag there."
#
# GATED ON THE DISCLAIMER CLAUSE, never on the negation. "the change does
# not touch the index, so queries stay slow" opens identically and is a
# finding; so is "this does not validate the input, so a malformed ARN is
# accepted". Both reach this regex and neither matches it.
#
# This and the two above are the only rules here that read ENGLISH, and they
# are content rules rather than transport ones: a schema says what shape a
# finding has, not whether its sentence is a finding. The vocabulary rule
# that DID belong to the transport -- deciding whether two differently-worded
# bullets were one claim -- is gone with the transport, along with its
# 150-word stoplist and its merger.
SELF_DISCLAIM = re.compile(
    r"(?:"
    # "flag", "report", "raise" and "note" are what a REVIEWER does, so a
    # finding whose sentence contains them is talking about the review.
    r"\bnothing (?:to|worth) (?:flag|report|raise|note)"
    # "fix", "change", "address" and "do" describe code perfectly well --
    # "the retry loop has nothing to change between attempts, so it spins
    # forever" is a real finding, and the unscoped form ate it. These count
    # only where the sentence ends there or scopes itself to the review.
    r"|\bnothing (?:to|worth) (?:fix|change|address|do)"
    r"(?= here\b| there\b| in this\b| in the (?:diff|patch)\b|[\s.!]*$)"
    r"|\bno (?:issue|issues|problem|problems|concern|concerns|finding"
    r"|findings|defect|defects) (?:here|there|found|identified|detected"
    r"|to report|in this|with this)\b"
    r"|\bno (?:further )?(?:action|changes?) (?:is |are |was |were )?"
    r"(?:needed|required|necessary)\b"
    r"|\b(?:this|that|it) is not (?:an? )?(?:issue|problem|concern|finding"
    r"|defect)\b"
    r")",
    re.IGNORECASE,
)

# An artefact whose whole content is WORDS ABOUT the code -- a comment, a
# docstring, a README, a runbook. Editing one cannot change what anything
# does, which is why a disagreement between two of them is not a finding
# where a disagreement between one of them and the CODE is.
PROSE_NOUN = (
    r"(?:code |doc |header |boundary |inline |leading |trailing |block )?"
    r"(?:comments?|docstrings?|documentation|readme|runbook)"
)

# What a prose disagreement looks like when it DOES matter: it leads
# somebody to do the wrong thing. That is a finding and this rule must not
# eat it, so either word vetoes the drop outright.
#
# "The README and the CHANGELOG contradict each other about the minimum
# version, so users install the wrong one" is prose against prose by every
# other test here, and it is reportable. Deliberately only these two: a
# human noun is not enough ("a reader of this file" appears in findings
# that are purely about prose), and `incorrect` is what a prose-only
# finding says about the prose itself.
PROSE_CONSEQUENCE = re.compile(r"\bmislead(?:s|ing)?\b|\bwrong\b", re.IGNORECASE)

# The verbs that say two things do not agree.
DISAGREE = r"(?:(?:contradict|disagree|conflict|match)(?:s|es|ed|ing)?|inconsistent)"

# A gap that may not cross a conjunction or a comma. This is what stops the
# rule reading ACROSS a second party into a prose noun that is not the one
# doing the disagreeing. Without it, "the comment says the retry count is 3
# but the loop runs 5 times, which contradicts the documentation" matched
# from `comment` to `documentation` and dropped a finding about the LOOP.
CLAUSE = r"(?:(?!\band\b|\bor\b)[^.;:!?,]){0,40}?"

# Mechanism 14. A finding whose two disagreeing parties are BOTH prose.
#
# Measured 2026-10-29: a whole review whose entire output was one of these.
# "The boundary comment on <resource> (and the one near line 40) still says
# the deploy role reads the init report after deploy, which this PR marks
# SUPERSEDED at line 55, so the comments now contradict each other; add a
# one-line superseded note to both." Two code comments disagreeing. Nothing
# can break, nothing is exposed, no control stops holding -- so there is no
# severity under which it is a finding, and moving it to a lower tier that
# still prints would not help. It must not print.
#
# BOTH PARTIES MUST BE NAMED, AND BOTH MUST BE PROSE. An earlier version
# claimed that and did not do it: it accepted `each other` as the second
# party, and `each other` names nothing, so only the LEFT side was ever
# checked. Measured end to end, that silently deleted this BLOCKER --
#
#   "The documentation and the code contradict each other about whether the
#    token is validated: the docs say every request is checked, the handler
#    skips validation when the header is absent, so a caller with no
#    token reaches the admin route."
#
# -- to REVIEW_FINDINGS=0 and a clean verdict. Hence two explicit branches:
#
#  1. THE SECOND PARTY IS NAMED, and named as prose: "no longer matches the
#     docstring", "is inconsistent with the README". Both ends are nouns
#     this rule recognises, so there is nothing to infer.
#  2. THE SECOND PARTY IS `each other`, which names nothing, so the SUBJECT
#     has to carry both parties by itself -- a prose noun that OPENS its
#     clause with nothing conjoined into it. "the comments now contradict
#     each other" qualifies.
#     "The documentation and the code contradict each other" does not: the
#     clause opens on `documentation` and `CLAUSE` will not cross the `and`,
#     and it cannot re-anchor on `code`, which is not a prose noun. Nor does
#     "The code and the README contradict each other" -- `README` is prose
#     but does not open the clause, and reading it as the subject is exactly
#     the inference that deleted the BLOCKER above.
#
# What branch 2 costs is "The docs and the comments contradict each other",
# where both really are prose and the conjunction blocks the match. That is
# a MISS, and a miss is a line of filler on a pull request while a wrong
# match deletes a real finding where nobody sees it. This branch DROPS, like
# CONVENTION and SELF_DISCLAIM, so it is written to miss.
PROSE_ONLY = re.compile(
    r"(?:"
    rf"\b{PROSE_NOUN}\b{CLAUSE}\b{DISAGREE}[^.;:!?]{{0,20}}?"
    rf"\b(?:with )?(?:the |that |this |its |a |an )?{PROSE_NOUN}\b"
    r"|"
    rf"(?:^|[,;:] )(?:so |and )?(?:the |these |both |two )?{PROSE_NOUN}\b"
    rf"{CLAUSE}\b{DISAGREE}[^.;:!?]{{0,20}}?"
    r"\b(?:each other|one another|themselves)\b"
    r")",
    re.IGNORECASE,
)

# Everything that is not a letter or a digit, for the IDENTITY test in
# `collapse`: two findings whose messages differ only by punctuation or case
# are one finding reported twice.
NORMALISE = re.compile(r"[^a-z0-9]+")

# Reason codes for a blindness claim, derived from the manifest row the
# finding cites. A reason code is what a coverage status is allowed to say;
# a severity is not.
REASONS = {
    "binary": "BINARY",
    "omitted": "BUDGET",
    "-": "NOPATCH",
}

# What the job log calls each drop.
DROP_LOG = {
    "padding": "padding rejected (citation absent at base)",
    "disclaimer": "self-disclaiming finding rejected",
    "prose": "prose-only disagreement rejected (nothing it names can change behaviour)",
}

# How many characters the whole comment body may run to. The old contract
# put this on the model and it was the cap that bound; it is enforced here
# now, by dropping the least severe findings, because a limit the producer
# polices is a limit the producer can miss.
BODY_LIMIT = 4000

# How many findings reach the comment. Blockers are kept before risks.
FINDING_LIMIT = 5

# How many characters of the head SHA the comment renders. SEVEN, because
# that is what the workflow already prints -- `${HEAD_SHA:0:7}` in the run
# context it hands the model, `.github/workflows/claude-pull-request-review.yaml`
# at the "Reviewed PR head" line. A second spelling of a commit in the same
# estate is a second thing to recognise.
SHORT_SHA = 7

# How the anchor line renders the time. UTC and minute resolution: the
# reader is matching a comment against a push, which is a question about
# which minute, and a local-time stamp in a comment read from three
# timezones is a question rather than an answer.
STAMP = "%Y-%m-%d %H:%M UTC"

# `owner/repo`, exactly as the runner sets GITHUB_REPOSITORY, and a full
# hex SHA. Both are CHECKED rather than trusted before they are built into
# a URL: the shapes are narrow, GitHub guarantees them, and a value that
# does not match simply loses the link instead of putting an arbitrary
# string inside a markdown target. `--head` is not always a SHA -- it
# defaults to the literal `unknown` -- which is the other reason this is a
# test and not an assumption.
REPO_SLUG = re.compile(r"[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}")
FULL_SHA = re.compile(r"[0-9a-f]{7,40}")

# The length bounds `review-schema.json` declares, re-stated here for the
# same reason SEVERITIES is: this program is the SECOND WITNESS to the CLI's
# validation, and a bound only the schema knows about is one this program
# cannot witness. Both are checked against the raw field, before any
# normalisation, because that is the string the schema measured.
#
# WHERE 2000 COMES FROM. The schema asks the model for 400 characters, so a
# message written to the instruction has five times the room it was asked
# for and is never refused for length. The ceiling that matters is GitHub's
# 65,536-character comment limit, beyond which the POST fails and the whole
# review is lost down the "could not run" path: FINDING_LIMIT messages at
# this bound is 10,000 characters, 15% of that, leaving the header, the
# disclosure sections and the marker the rest. It is deliberately ABOVE the
# 4,000-character BODY_LIMIT, which is a readability budget `assemble`
# already enforces by dropping findings and counting what it dropped --
# overrunning that is accounted for, overrunning GitHub's is not.
MESSAGE_LIMIT = 2000

# PATH_MAX. The longest path the checkout under review can contain, so no
# real finding is refused by it; it exists to stop an unbounded string
# reaching the body, not to second-guess the repository.
PATH_LIMIT = 4096

# Every C0 control character and DEL. In a message these are collapsed to
# spaces: the body is assembled LINE BY LINE, so a newline inside a message
# ends the bullet and whatever follows becomes body text -- a cold review
# used one to add a sixth `- **BLOCKER**` bullet to a comment whose header,
# marker and metrics all said five, which is the exact invariant `assemble`
# exists to hold.
CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]")

# HTML comment delimiters. The state marker is an HTML comment and
# `previous_stats` parses it, so a message carrying one can forge the
# measurement the regression detector compares against. Unlike a newline
# this has no benign reading in a one-sentence finding, so it refuses the
# finding rather than being rewritten.
MARKER_DELIMS = ("<!--", "-->")

# The refusal tally `load` returns. Every exit from it carries this shape --
# an early return of a bare 0 for the count was the same tuple with a
# different type in one slot, and the caller subscripts it.
REFUSALS = ("schema", "unsafe", "normalised")

# Flags this program accepts. An unknown one is misuse -- see `check_flags`.
FLAGS = (
    "--findings",
    "--manifest",
    "--base",
    "--out",
    "--sections",
    "--notes",
    "--previous",
    "--metrics",
    "--head",
    "--lane",
    "--coverage-read",
    "--coverage-total",
    "--summary",
    "--restored",
)


def manifest_rows(path: str) -> dict:
    """{repo path: (status, patch token)} from the manifest."""
    return {row[1]: (row[0], row[2]) for row in review_io.read_manifest(path)}


def base_paths(base: str) -> set:
    """Every path tracked at the base ref.

    This is the set a "you did not add X" finding has to cite something
    from. It comes from the BASE and not the working tree, because the
    question the gate asks is whether the convention existed for the author
    to follow -- a CHANGELOG the pull request itself adds does not make a
    pre-existing CHANGELOG rule real, and one it deletes does not make the
    rule vanish.

    An empty set on failure, which makes the gate reject every convention
    finding rather than accept every one. Failing toward "drop it" is right:
    the thing being gated is padding, and a run that cannot check loses a
    little signal, while the other direction loses the whole mechanism.
    """
    try:
        out = subprocess.run(
            [
                "git",
                "-c",
                "core.quotePath=false",
                "ls-tree",
                "-r",
                "-z",
                "--name-only",
                base,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"review_output: cannot list the base tree: {exc}", file=sys.stderr)
        return set()
    return {p.decode("utf-8", "surrogateescape") for p in out.split(b"\x00") if p}


def line_count(path: str) -> int:
    """Lines in a working-tree file, or -1 when it cannot be read.

    Counted in chunks rather than read whole: this runs against the pull
    request's own checkout, where a file's size is the author's choice.

    NEWLINES ARE TERMINATORS, NOT SEPARATORS, which is the convention every
    tool the reader will reach for uses -- `wc -l`, an editor's gutter, and
    the line numbers GitHub renders beside the blob. Returning
    `newlines + 1` added a phantom final line to every file that ends in a
    newline, which is almost all of them, so a 3-line file accepted an
    anchor at line 4 and the prompt's "a line past the end of the file costs
    the finding its severity" cost nothing for the first line past it.

    THE FILE WITH NO TRAILING NEWLINE is the case the terminator reading has
    to be deliberate about: its last line is real and unterminated, so it is
    counted, and the discriminator is the last byte rather than a `+ 1`
    applied to everything. An empty file is 0 lines and therefore has no
    valid anchor at all, where the old form claimed it had one.

    ONLY A REGULAR FILE IS COUNTED, because a symlink defeats both path
    checks below: one to `/dev/zero` makes the chunk loop endless -- it
    bounds memory, not time -- and one out of the tree answers from content
    the reviewer never saw. Refused rather than capped: a cap still measures
    the wrong file, and would downgrade a finding in a large tracked one.
    """
    if os.path.isabs(path) or ".." in path.replace(os.sep, "/").split("/"):
        return -1
    try:
        if os.path.islink(path) or not os.path.isfile(path):
            return -1
        total, last = 0, b""
        with open(path, "rb") as handle:
            while True:
                chunk = handle.read(1 << 16)
                if not chunk:
                    break
                total += chunk.count(b"\n")
                last = chunk[-1:]
        return total if last in (b"", b"\n") else total + 1
    except OSError:
        return -1


def reason_for(path: str, rows: dict) -> str:
    """The coverage reason code for a path the reviewer says it could not see."""
    if path not in rows:
        return "EXCLUDED"
    status, token = rows[path]
    if token == "-" and status == "removed":
        return "DELETED"
    return REASONS.get(token, "UNREAD")


class Verdict:
    """One finding and what adjudication did to it."""

    # pylint: disable=too-few-public-methods,too-many-instance-attributes

    def __init__(
        self,
        severity: str,
        path: str,
        line: int,
        message: str,
        normalised: bool = False,
    ):
        # pylint: disable=too-many-arguments,too-many-positional-arguments
        self.severity = severity
        self.path = path
        # True when `build_verdict` collapsed a control character out of the
        # message. Carried on the finding rather than counted in passing so
        # the job log can name WHICH finding arrived with one.
        self.normalised = normalised
        # The line AS THE REVIEWER GAVE IT. Mechanism 4 zeroes `self.line`
        # on a downgrade, and `collapse` must still be able to tell two
        # findings at different lines apart afterwards.
        self.given = line
        self.line = line
        self.message = message
        self.dropped = ""
        self.reason = ""

    def location(self) -> str:
        """The finding's anchor as it will appear in the comment body.

        `-` for a repo-wide finding: the schema's "no path" is the empty
        string, which renders as nothing at all, and a bare pair of
        backticks in the comment reads as a path that failed to print.
        """
        if not self.path:
            return "-"
        return f"{self.path}:{self.line}" if self.line else self.path

    def line_out(self) -> str:
        """The finding as it will appear in the comment body."""
        return f"- **{self.severity}** `{self.location()}` — {self.message}"


def normalise(message: str) -> str:
    """A message reduced to what it says. An identity test, nothing more."""
    return NORMALISE.sub(" ", message.lower()).strip()


def load(path: str) -> tuple:
    """(findings, {reason: count} for what was refused, True when supplied).

    The file is review_text.py's output: the CLI's `structured_output`, or
    nothing when the run produced none. A missing file, an unreadable one,
    something that is not an object, or an object with no `findings` array
    all mean the same thing -- nothing was adjudicated -- and the third
    element says so. That is a FACT about the run, where the heuristic it
    replaces ("no finding parsed, no verdict line, and some stray text") was
    an inference from how prose happened to fail.

    An entry that is not an object of the declared shape is REJECTED and
    counted, never repaired. Repairing one -- a truncation, a default, a
    guess at a severity -- is what the markdown layer did, and every one of
    those repairs was a defect found later.

    The two refusal reasons are kept apart because they mean different
    things. `schema` is this program and the CLI DISAGREEING about an object
    the CLI already validated, which is a defect in one of them. `unsafe` is
    both of them agreeing the object conforms while its text would forge the
    comment's own structure, which the schema cannot express and so is not a
    disagreement at all.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
    except OSError:
        return [], dict.fromkeys(REFUSALS, 0), False
    if not raw.strip():
        return [], dict.fromkeys(REFUSALS, 0), False
    try:
        document = json.loads(raw)
    except ValueError as exc:
        print(f"review_output: the findings file is not JSON: {exc}", file=sys.stderr)
        return [], dict.fromkeys(REFUSALS, 0), False
    if not isinstance(document, dict) or not isinstance(document.get("findings"), list):
        print(
            "review_output: the findings file carries no `findings` array",
            file=sys.stderr,
        )
        return [], dict.fromkeys(REFUSALS, 0), False

    findings = []
    refused = dict.fromkeys(REFUSALS, 0)
    for entry in document["findings"]:
        verdict = build_verdict(entry)
        if isinstance(verdict, str):
            refused[verdict] += 1
            continue
        if verdict.normalised:
            refused["normalised"] += 1
        findings.append(verdict)
    return findings, refused, True


def build_verdict(entry):
    """One Verdict from one schema object, or `"schema"` / `"unsafe"`.

    `conforms` holds the half the schema can express; the rest is here.

    MECHANISM 12 LIVES HERE: the boundary where model text stops being able
    to write the comment's own structure. One crafted document produced
    three defects against the version without it -- a `- **BLOCKER**`
    bullet no count included, a forged marker placed before the real one,
    and a code span broken by a backtick in `path`.

    COLLAPSE OR REFUSE, per field, by whether the character has a benign
    reading:

    * A CONTROL CHARACTER IN `message` IS COLLAPSED TO A SPACE. A model
      wrapping two sentences across a newline is writing a correct finding
      badly, and `message` was already `.strip()`ped -- this is the same
      operation on the interior. Refusing would discard real findings to
      defeat what collapsing already defeats. Counted anyway: that count is
      the evidence that would justify tightening this later.
    * `<!--` OR `-->` IN `message` REFUSES IT. No benign reading in one
      sentence of prose, and collapsing cannot help -- the marker
      `previous_stats` reads is an HTML comment, which forges inline.
    * A BACKTICK OR CONTROL CHARACTER IN `path` REFUSES IT. The path is
      rendered inside an inline code span, and unlike a message it has no
      prose to preserve: a path that cannot be printed is not an anchor.

    A refusal is counted and disclosed through `dropped_total` and
    `drop_section`, the accounting every other withholding goes through.
    """
    if not isinstance(entry, dict):
        return "schema"
    severity = entry.get("severity")
    path = entry.get("path")
    line = entry.get("line")
    message = entry.get("message")
    if not conforms(severity, path, line, message):
        return "schema"
    if path and ("`" in path or CONTROL_CHARS.search(path)):
        return "unsafe"
    if any(delim in message for delim in MARKER_DELIMS):
        return "unsafe"
    normalised = bool(CONTROL_CHARS.search(message))
    clean = " ".join(CONTROL_CHARS.sub(" ", message).split())
    if not clean:
        # Every character was a control character, so `message.strip()`
        # found something and there is still nothing to print.
        return "schema"
    return Verdict(severity, path, line, clean, normalised)


def conforms(severity, path, line, message) -> bool:
    """Everything `review-schema.json` declares, checked a second time.

    `line` is accepted as an integer only. A string "36" is not an integer
    and is refused rather than coerced: the schema declares the type, so a
    string there means the validation that was supposed to enforce it did
    not run, and coercing would hide exactly that.

    The lengths are measured on the RAW field, before any normalisation,
    because that is the string the schema measured -- a second witness that
    checked something else would not be one.
    """
    if severity not in SEVERITIES:
        return False
    if not isinstance(path, str) or not isinstance(message, str):
        return False
    if not message.strip():
        return False
    # `bool` is a subclass of `int`, and `True` as a line number would
    # resolve to line 1 on any file with content.
    if isinstance(line, bool) or not isinstance(line, int) or line < 0:
        return False
    if len(message) > MESSAGE_LIMIT or len(path) > PATH_LIMIT:
        return False
    return not (path and (os.path.isabs(path) or path.startswith("./")))


def anchor_verdict(
    finding: "Verdict", known: bool, restored: tuple, counts: dict
) -> None:
    """Mechanism 4, and the one class of path it cannot be applied to.

    At a RESTORED path the working tree holds the BASE's file, so a line
    number is tested against content the reviewer was never shown and the
    answer is meaningless either way -- a pass as unearned as a failure.
    The severity stands; `restored_section` discloses the unchecked anchor.

    Zeroing the line was the alternative, and is rejected: it is the
    reviewer's, read off the patch in `pr-files/`, and deleting a true
    locator to signal "unverified" costs more than the disclosure does.
    """
    if known and review_io.under(finding.path, restored):
        if finding.line:
            counts["unverified"] += 1
        return
    if known and (
        finding.line == 0 or 0 < finding.line <= max(line_count(finding.path), 0)
    ):
        return
    # Downgrade and drop the number. Never the other direction: a claim
    # the reviewer cannot point at is weaker than one it can, and the
    # model does not get to certify its own.
    if finding.severity == "BLOCKER":
        finding.severity = "RISK"
    finding.line = 0
    counts["anchor"] += 1


def adjudicate(findings: list, rows: dict, base: set, restored: tuple = ()) -> dict:
    """Apply every rejection rule. Returns the counts; mutates `findings`.

    Order matters. Blindness is tested FIRST, because a blindness claim
    about a file with no patch would also read as a convention assertion
    ("no patch available") and would then be counted as padding -- two
    different defects with two different meanings, and conflating them
    would make the padding metric useless.
    """
    counts = {
        "blind": 0,
        "padding": 0,
        "anchor": 0,
        "disclaimer": 0,
        "prose": 0,
        "unverified": 0,
    }
    for finding in findings:
        path = finding.path

        if BLINDNESS.search(finding.message):
            finding.dropped = "blind"
            finding.reason = reason_for(path, rows)
            counts["blind"] += 1
            continue

        # After blindness, which is the more informative reading of "I
        # could not see it, so there is nothing to flag" -- that one is a
        # coverage fact with a reason code, not padding.
        if SELF_DISCLAIM.search(finding.message):
            finding.dropped = "disclaimer"
            counts["disclaimer"] += 1
            continue

        # Mechanism 14, and it is tested BEFORE the empty-path shortcut
        # below: a prose-only disagreement is reportable repo-wide as
        # readily as at a line, and the shortcut would let that spelling
        # of it through.
        #
        # A BLOCKER IS NEVER DROPPED HERE, whatever the sentence looks
        # like. The two errors are not symmetrical: a prose nit the model
        # called a BLOCKER is one visible line somebody can argue with,
        # and a real BLOCKER deleted by a regex is invisible. This floor
        # is mechanism 14's alone -- every other rule still drops blockers,
        # because each of those tests a fact about the repository rather
        # than reading the sentence for its subject.
        #
        # The two checks after it are one decision: both parties named as
        # prose, AND nothing in the sentence says a human acts wrongly on
        # the difference.
        if (
            finding.severity != "BLOCKER"
            and PROSE_ONLY.search(finding.message)
            and not PROSE_CONSEQUENCE.search(finding.message)
        ):
            finding.dropped = "prose"
            counts["prose"] += 1
            continue

        # The empty path is the schema's token for "this finding is
        # repo-wide", so it is an absence of an anchor rather than a broken
        # one. Running it through the resolution test below downgraded every
        # deliberate repo-wide BLOCKER to a RISK -- punishing the reviewer
        # for using the token correctly, which is the opposite of the intent.
        if not path:
            continue

        if CONVENTION.search(finding.message) and path not in base and path not in rows:
            # Absent at base AND not in the change: there is no artefact here
            # to have been missing and no new file to have broken a rule.
            # The base alone is not the test -- every ADDED file is absent
            # there, which dropped real findings about new code as padding.
            #
            # A DROP, where the anchor rule below only downgrades, which is
            # why CONVENTION is scoped to the artefact nouns: anything wider
            # makes the two rules race on the same finding and the wording
            # decides which wins.
            finding.dropped = "padding"
            counts["padding"] += 1
            continue

        anchor_verdict(finding, path in rows or path in base, restored, counts)
    return counts


def collapse(findings: list) -> int:
    """Remove a finding the surviving list already carries, byte for byte.

    THE ONE PIECE OF DE-DUPLICATION THAT SURVIVED THE TRANSPORT, and the
    reason the rest did not. The old rule merged two findings when they
    shared ONE content word at one path, because markdown gave it nothing
    better: the #340 pair -- "It hardcodes account 123456789012, which also
    appears in the PR text" and "The README includes an AWS account ID" --
    shares only `account`. That rule needed a 150-word stoplist to stop it
    firing on function words, it wrongly collapsed "the install command
    points at the wrong branch" with "the build command is unquoted", and
    the merge it performed to make wrong collapses survivable is what
    produced the worst defect this program has had: a merged message longer
    than the whole comment budget, cut to fit, deleting two security
    blockers under a sentence saying nothing had been discarded.

    Structured output removes the question it was answering. A finding is an
    object with a severity, a path, a line and a message, so "the same
    finding twice" is an identity, not a judgement about shared vocabulary:
    same path, same line, same message once punctuation and case are set
    aside. NOTHING IS MERGED, because there is nothing to merge -- the copies
    are the same sentence -- so no message grows and the budget defect
    cannot recur.

    Two genuinely distinct findings about one file now BOTH survive, which
    is the failure the old rule traded away and this one does not.

    The highest severity in the group wins, so a defect reported once as a
    BLOCKER and once as a RISK keeps the BLOCKER.
    """
    seen: dict[tuple[str, int, str], Verdict] = {}
    collapsed = 0
    for finding in findings:
        if finding.dropped:
            continue
        key = (finding.path, finding.given, normalise(finding.message))
        first = seen.get(key)
        if first is None:
            seen[key] = finding
            continue
        if finding.severity == "BLOCKER":
            first.severity = "BLOCKER"
        finding.dropped = "duplicate"
        collapsed += 1
    return collapsed


# Everything adjudication removed that a READER has to be told about. The
# reason each is here is the same one: it might have been a finding, so a
# comment that did not mention it would be indistinguishable from a clean
# verdict over a real defect.
#
# A DUPLICATE is deliberately absent: its text is in the comment on the copy
# that survived, so counting it as dropped would claim a withholding that
# never was.
#
# A PROSE-ONLY REJECTION IS ABSENT FOR A DIFFERENT REASON, and it is the
# only member of mechanism 14's class: it is not a finding that was
# withheld, it is text that was never a finding. Disclosing it puts "1
# finding dropped before posting" on a pull request whose correct output is
# the clean verdict, which reads as the reviewer concealing something --
# measured 2026-10-29, and the complaint this rule exists to answer. It
# stays where an engineer can audit it in full: the job log names it
# through DROP_LOG, `REVIEW_PROSE_REJECTED` counts it, and the marker
# records it.
DISCLOSED = ("padding", "blind", "disclaimer", "schema", "unsafe")

# Everything adjudication removed, full stop. The MARKER's number, not the
# comment's. The marker is an HTML comment -- invisible to every reader and
# parsed by nothing but `previous_stats`, which reads `findings=` -- so
# there is no reason for it to lose a fact, and every reason for the one
# machine-readable record of the run to be complete.
RECORDED = DISCLOSED + ("prose",)


def dropped_total(counts: dict, keys: tuple = DISCLOSED) -> int:
    """How many findings adjudication removed, over `keys`.

    TWO CALLERS AND TWO ANSWERS, which is the whole point of the argument.
    `DISCLOSED` is what the header counts and what gates `drop_section`;
    `RECORDED` is what the marker carries. They differ by exactly the
    prose-only rejections -- see DISCLOSED for why that is not a hole.
    """
    return sum(counts.get(key, 0) for key in keys)


def rank(findings: list) -> list:
    """Findings that survived adjudication, blockers first. UNCAPPED.

    FINDING_LIMIT is applied by the caller, which counts what the cap
    removed. Applied here, findings 6..N were discarded with no number
    anywhere -- not in the comment, not in the header, not in the metrics.
    """
    kept = [f for f in findings if not f.dropped]
    kept.sort(key=lambda f: 0 if f.severity == "BLOCKER" else 1)
    return kept


class Tally(NamedTuple):
    """What the header and the marker have to agree about.

    One object because they are two renderings of the same facts, and they
    were once computed from a different list than the comment carried: the
    header counted the findings before trimming, the body held the ones
    after.

    `adjudged` AND `recorded` ARE THE ONE PLACE THEY LEGITIMATELY DIFFER,
    and they differ by the prose-only rejections alone -- the header tells a
    reader what was withheld from them, the marker records everything the
    run did. Both are computed in `build` from the same `counts`, so neither
    can drift from the other by accident.
    """

    shown: list
    adjudged: int
    recorded: int
    space: int
    read: str
    total: str


def coverage_note(read: str, total: str) -> str:
    """How much was opened, as a clause for the headline. EVERY headline.

    The clean line is what goes out over a thin review, and "40 files,
    +6654/-724" says nothing about how many of them were opened: 2 read of
    40 posted identically to 40 read of 40, which is the 2026-10-21 failure
    with a footnote on it.

    A headline that DOES carry findings needs it just as much. Three
    findings over 2 files of 40 is the `unmeasured` case wearing a verdict:
    the reader has no way to tell it from three findings over all 40.

    `unmeasured` is a TOKEN, not a number, and must never render as one.
    `0/0` is what the flags default to when the workflow did not supply
    them, so it is treated as absent rather than as a measured nothing.
    """
    if read.isdigit() and total.isdigit():
        if total == "0":
            return ""
        noun = "file" if total == "1" else "files"
        return f" in the {read} of {total} {noun} opened"
    return " (review coverage unmeasured)"


def header(tally: Tally, summary: str, unread: bool = False) -> str:
    """The one-line header, counted from the findings IN THE COMMENT."""
    if unread:
        # NOT the clean header. Nothing in this output was adjudicated, so
        # the comment says so rather than reporting an absence of findings
        # that was never established.
        return (
            "**The reviewer produced no structured output.** No finding and"
            " no verdict could be read from the run, so nothing on this pull"
            " request has been adjudicated by this check."
        )
    note = coverage_note(tally.read, tally.total)
    if not tally.shown:
        if tally.adjudged:
            # NOT the clean header either. Something WAS adjudicated and
            # removed; "no blocking findings" would report an absence that
            # was never established. A sole security BLOCKER dropped as
            # padding went out as a pass with its only record on stdout.
            noun = "finding" if tally.adjudged == 1 else "findings"
            return (
                f"**No finding survived adjudication{note}.**"
                f" {tally.adjudged} {noun} dropped before posting; see below."
            )
        clean = f"**No blocking findings{note}.**"
        return f"{clean} {summary}" if summary else clean
    blockers = sum(1 for f in tally.shown if f.severity == "BLOCKER")
    risks = len(tally.shown) - blockers
    noun = "finding" if len(tally.shown) == 1 else "findings"
    tail = f" {tally.space} withheld for space." if tally.space else ""
    return (
        f"**{len(tally.shown)} {noun}{note}** — {blockers}"
        f" blocker{'' if blockers == 1 else 's'},"
        f" {risks} risk{'' if risks == 1 else 's'}.{tail}"
    )


def anchor(head: str, when: str, repo: str = "") -> str:
    """Which commit this review describes, and when it was written.

    MECHANISM 13. The comment is EDITED IN PLACE on every push -- a
    deliberate decision, recorded at the PATCH in "Post or update the review
    comment": editing preserves the comment's revision history, where
    delete-and-repost throws it away and moves the review to the bottom of
    the thread. The cost GitHub imposes for it is that an edited comment
    renders at its ORIGINAL creation position and under its ORIGINAL
    timestamp. Measured 2026-10-29: a current review, updated at 16:13,
    displayed to every reader as a comment dated sixteen days earlier.

    The commit was never missing -- it was in the state marker, which is an
    HTML comment and therefore invisible to every human reading the thread.
    A reader had no way to tell which commit the review described, or that
    it described the current one at all.

    SAME SOURCE AS THE MARKER, deliberately. `build` resolves `--head` once
    and hands the same string to this and to `marker`, so the line a human
    reads and the field the workflow matches on cannot disagree. Rendered
    from two lookups they could, and the invisible one would be the one that
    stayed right.

    THE LINK IS AN ADDITION, NEVER A SUBSTITUTION. `repo` is the runner's
    own `GITHUB_REPOSITORY`, not an input anybody plumbs, so when it is
    absent -- every fixture here, and anything running outside Actions --
    the line renders exactly as it does with it, minus the link. A reader
    can then confirm the SHA is the head without leaving the page; where
    the value is missing or malformed they are no worse off than before.
    """
    short = f"`{head[:SHORT_SHA]}`"
    if REPO_SLUG.fullmatch(repo) and FULL_SHA.fullmatch(head):
        short = f"[{short}](https://github.com/{repo}/commit/{head})"
    return f"Reviewed {short} at {when}."


def drop_section(counts: dict) -> tuple:
    """The comment row that says what adjudication removed, and why.

    Mechanism 7. A drop used to be recorded nowhere but stdout, so a sole
    finding dropped by the padding or the blindness rule reached the pull
    request as "No blocking findings." with no trace of it at all.

    THE ROWS ARE `DISCLOSED`, NOT `RECORDED`, so mechanism 14 has no row
    here and never will -- see DISCLOSED. Every other class keeps its row
    untouched; this is one exception with one reason, not a precedent.
    """
    parts = []
    for key, why in (
        ("padding", "padding (citation absent at base)"),
        ("blind", "blindness (recorded as coverage)"),
        ("disclaimer", "self-disclaiming (its own text says there is nothing to flag)"),
        ("schema", "rejected by the output schema check"),
        (
            "unsafe",
            "refused for text that would forge the comment's own structure"
            " (a newline or an HTML comment in the message, a backtick in"
            " the path)",
        ),
    ):
        if counts.get(key):
            parts.append(f"{counts[key]} {why}")
    return ("Findings dropped before posting", ", ".join(parts))


def duplicate_section(count: int) -> tuple:
    """The row that says a finding was reported twice, not that one was cut."""
    phrase = "finding was" if count == 1 else "findings were"
    return (
        "Duplicates removed",
        f"{count} {phrase} reported more than once, identically. One copy of"
        " each is in the comment above; no distinct wording was discarded.",
    )


def restored_section(count: int) -> tuple:
    """Mechanism 11's disclosure: the anchor was not checked, not nothing.

    Without it the finding reads as though its line had been resolved
    against the checkout, which at a restored path it cannot be.
    """
    phrase = "finding cites" if count == 1 else "findings cite"
    return (
        "Anchors not checked",
        f"{count} {phrase} a path reverted to base content before the"
        " review ran, so the line numbers could not be checked against the"
        " checkout. The severity stands.",
    )


def read_sections(path: str) -> list:
    """[(label, text)] from a TSV file, skipping any row with no text.

    The skip is mechanism 1. The workflow writes a row for every
    disclosure it might make and leaves the text empty when there is
    nothing to disclose, so "only if a finding populates it" is enforced
    here once rather than by a conditional per section in the workflow.
    """
    if not path or not os.path.exists(path):
        return []
    out = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            label, _, text = line.rstrip("\n").partition("\t")
            if label.strip() and text.strip():
                out.append((label.strip(), text.strip()))
    return out


def marker(lane: str, tally: Tally, head: str) -> str:
    """The state marker. Written HERE, never asked of the model.

    The comment's identity as a piece of STATE -- which run, which head, how
    much was covered -- and what the workflow matches on when it goes looking
    for the comment to edit. It was previously the model's last line, where a
    malformed one was simply unreadable and nothing noticed; `read=` in
    particular is the measurement, so it could never have come from there.

    `findings=` is what the comment CARRIES, `dropped=` everything
    adjudication or the budget removed. Without the second, `findings=0
    blockers=0` meant both "nothing was found" and "everything was dropped".
    """
    blockers = sum(1 for f in tally.shown if f.severity == "BLOCKER")
    return (
        f"<!-- claude-review v3 lane={lane} findings={len(tally.shown)}"
        f" blockers={blockers} dropped={tally.recorded + tally.space}"
        f" read={tally.read}/{tally.total} head={head} -->"
    )


def previous_stats(path: str) -> tuple:
    """(characters, findings) of the comment this run is replacing.

    THE LAST MARKER, NEVER THE FIRST. `compose` writes the marker as the
    final line of the body, so the real one is always last and anything
    earlier claiming to be one was put there by something else. With
    `re.search` the first match won, which let a marker forged in a finding
    drive the regression detector -- the detector whose whole job is to
    catch a review that grew while saying less being fed its comparison by
    the review it is comparing against. `build_verdict` now refuses a
    message carrying `<!--`, so this is the second of the two; it is kept
    because it costs one line and because it holds whatever the first lets
    through.
    """
    if not path or not os.path.exists(path):
        return 0, -1
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        body = handle.read()
    found = re.findall(r"<!-- claude-review v\d+ [^>]*findings=(\d+)", body)
    return len(body), int(found[-1]) if found else -1


def assemble(findings: list, sections: list, render) -> tuple:
    """(body, the findings the body actually carries).

    Trimmed to BODY_LIMIT by dropping the least severe finding until it fits
    -- never by shortening one. The sections are disclosures about what was
    NOT reviewed, so they are never what gets dropped to make room.

    WHEN ONE FINDING IS LEFT, THE BUDGET YIELDS. The previous version cut
    that finding's text, which it needed because a MERGED message could run
    longer than the whole budget -- and that cut is what deleted two security
    blockers from a comment whose own sentence said nothing had been
    discarded. Nothing is merged now, so the only routes here are one very
    long message or a very large disclosure section, and in both a comment
    slightly over a self-imposed limit beats a shortened finding. BODY_LIMIT
    is a readability budget; GitHub's platform limit is 65,536.

    `render(shown)` is called again after every trim. Computed once from the
    untrimmed list, a BLOCKER could vanish from the body while the header
    still counted it. Nothing may claim a finding is in the comment when it
    is not.
    """
    kept = list(findings)
    while True:
        body = compose(kept, sections, render)
        if len(body) <= BODY_LIMIT or len(kept) <= 1:
            return body, kept
        kept.pop()


def compose(kept: list, sections: list, render) -> str:
    """The comment body for exactly the findings `kept` holds.

    The anchor sits directly under the headline rather than at the foot,
    because it answers the first question a reader of an edited comment has
    -- is this about the commit I just pushed -- and an answer below five
    findings and three disclosure sections is one they reach after deciding
    whether to trust them.
    """
    body_header, body_anchor, state = render(kept)
    parts = ["## Claude Code Review", "", body_header, "", body_anchor]
    if kept:
        parts.append("")
        parts.extend(f.line_out() for f in kept)
    for label, text in sections:
        parts.extend(["", f"**{label}**", "", "```text", text, "```"])
    parts.extend(["", state, ""])
    return "\n".join(parts)


def build(argv: list, findings: list, counts: dict, sections: list) -> tuple:
    """(comment body, the findings it actually carries).

    The header and the marker are rendered from whatever survives trimming
    rather than from the list this was handed: both were computed once, so a
    finding dropped to fit the byte budget stayed counted in the header, in
    the marker and in the metrics. `counts["space"]` is set to how many were
    withheld -- by the FINDING_LIMIT cap and by the body budget together.
    """
    survived = rank(findings)
    lane = _flag(argv, "--lane", "B")
    head = _flag(argv, "--head", "unknown")
    read = _flag(argv, "--coverage-read", "0")
    total = _flag(argv, "--coverage-total", "0")
    summary = _flag(argv, "--summary")
    # READ ONCE, not per render. `assemble` calls `render` again after every
    # trim, so a clock read inside it can change the body between iterations
    # and would put a different minute in the comment than the one the body
    # was measured at.
    when = time.strftime(STAMP, time.gmtime())
    # The runner sets this on every job; nothing passes it in. See `anchor`.
    repo = os.environ.get("GITHUB_REPOSITORY", "")

    def render(shown: list) -> tuple:
        """(header, anchor, marker) for exactly the findings `shown` holds.

        BOTH TOTALS ARE TAKEN FROM `counts` HERE, not hoisted into two
        locals above. They are two views of one dictionary and nothing
        between here and there may change one without the other.
        """
        tally = Tally(
            shown,
            dropped_total(counts, DISCLOSED),
            dropped_total(counts, RECORDED),
            len(survived) - len(shown),
            read,
            total,
        )
        return (
            header(tally, summary, bool(counts["no_verdict"])),
            anchor(head, when, repo),
            marker(lane, tally, head),
        )

    body, kept = assemble(survived[:FINDING_LIMIT], sections, render)
    counts["space"] = len(survived) - len(kept)
    return body, kept


def _flag(argv: list, name: str, default: str = "") -> str:
    """One `--name value` flag, or `default`.

    A PAIRWISE WALK, not `argv.index`. The index form matched a flag name
    appearing as another flag's VALUE and returned the token after it --
    `--summary "see --head"` made `--head` resolve to `"see --head"`'s
    successor. `--summary` carries author-influenced text, so that was
    reachable from the pull request.

    Unknown flags are refused by `check_flags`, which `main` calls before
    anything here is read. This helper cannot do it: it is asked about one
    flag at a time and so never sees that a token belongs to no flag at all.
    """
    index = 0
    while index < len(argv):
        token = argv[index]
        if token not in FLAGS:
            index += 1
            continue
        if index + 1 >= len(argv):
            break
        if token == name:
            return argv[index + 1]
        index += 2
    return default


def check_flags(argv: list) -> list:
    """Every token that is neither a known flag nor the value of one.

    `_flag`'s docstring claimed unknown flags were fatal and nothing
    enforced it, so a mistyped `--coverage-total` silently became the "0"
    default and the comment went out reading "(review coverage
    unmeasured)" -- a wrong measurement rather than a loud failure, in a
    program built on the principle that an unmeasured thing must never
    render as a measured one. `review_coverage.parse_args` does enforce it,
    so the two helpers behaved differently while their docstrings agreed.

    Fatal is the right direction here and not everywhere: the workflow and
    these programs are checked out at ONE commit (`job_workflow_sha`), so a
    flag mismatch is not version drift between a caller and a callee, it is
    a defect inside a single commit, and the canary PR is where it should
    surface rather than fleet-wide and silent.

    A known flag with no value is misuse too, and is named the same way.
    """
    unknown, index = [], 0
    while index < len(argv):
        token = argv[index]
        if token not in FLAGS:
            unknown.append(token)
            index += 1
            continue
        if index + 1 >= len(argv):
            unknown.append(token)
            break
        index += 2
    return unknown


def main(argv: list) -> int:
    """Adjudicate the review and write the comment body."""
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0

    unknown = check_flags(argv)
    if unknown:
        print(
            "review_output: unknown or incomplete flag(s): " + " ".join(unknown),
            file=sys.stderr,
        )
        print(USAGE, file=sys.stderr)
        return 2

    found = _flag(argv, "--findings")
    manifest = _flag(argv, "--manifest")
    out = _flag(argv, "--out")
    if not found or not manifest or not out:
        print(USAGE, file=sys.stderr)
        return 2

    findings, refused, supplied = load(found)
    counts = adjudicate(
        findings,
        manifest_rows(manifest),
        base_paths(_flag(argv, "--base", "HEAD^")),
        tuple(_flag(argv, "--restored").split()),
    )
    counts["duplicate"] = collapse(findings)
    counts["schema"] = refused["schema"]
    counts["unsafe"] = refused["unsafe"]
    counts["normalised"] = refused["normalised"]
    # A run that produced no object at all adjudicated nothing. A run that
    # produced `{"findings": []}` adjudicated everything and found nothing,
    # which is a verdict and must not be confused with the first.
    counts["no_verdict"] = int(not supplied)

    sections = read_sections(_flag(argv, "--sections"))
    if dropped_total(counts, DISCLOSED):
        sections.append(drop_section(counts))
    if counts["duplicate"]:
        sections.append(duplicate_section(counts["duplicate"]))
    if counts["unverified"]:
        sections.append(restored_section(counts["unverified"]))
    body, kept = build(argv, findings, counts, sections)

    with open(out, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(body)

    report(kept, findings, counts, len(body))
    return metrics(argv, kept, counts, len(body))


def report(kept, findings, counts, size) -> None:
    """Everything adjudication did, on stdout, for the job log.

    Verbose on purpose: this is the step somebody reads when a finding they
    expected is not on the pull request, and "it was dropped as padding
    because `CHANGELOG.md` does not exist at the base ref" is the only
    answer that saves them an hour.
    """
    print(
        f"Parsed: {len(findings)} finding object(s),"
        f" {counts['schema']} rejected by the schema check,"
        f" {counts['unsafe']} refused as unsafe text."
    )
    if counts["no_verdict"]:
        print(
            "::warning::the reviewer produced no structured output, so no"
            " finding and no verdict could be read and nothing has been"
            " adjudicated"
        )
    if counts["schema"]:
        print(
            f"::warning::{counts['schema']} finding object(s) did not match"
            " review-schema.json after the CLI had already validated them;"
            " the two checks disagree and the objects were dropped"
        )
    if counts["unsafe"]:
        print(
            f"::warning::{counts['unsafe']} finding object(s) carried text"
            " that would forge the comment's own structure -- an HTML"
            " comment in the message, or a backtick or control character in"
            " the path -- and were dropped"
        )
    for finding in findings:
        if finding.normalised:
            print(
                "  control character(s) collapsed out of the message"
                f" {finding.location()}"
            )
    for finding in findings:
        if finding.dropped == "blind":
            print(
                f"  blindness -> coverage [{finding.reason}]"
                f" {finding.location()}: {finding.message[:120]}"
            )
        elif finding.dropped == "duplicate":
            print(f"  duplicate of an earlier finding {finding.location()}")
        elif finding.dropped == "prose":
            # IN FULL, AND AS AN ANNOTATION. Mechanism 14 is the only drop
            # class with no witness on the pull request, so this log line is
            # the whole record a human can audit -- and `[:120]` below cut
            # the measured BLOCKER mid-clause at "...whether the token is",
            # losing the half that proves the drop was wrong. The schema
            # caps `message` at MESSAGE_LIMIT, and `build_verdict` has
            # already collapsed every control character to a space, so this
            # is one bounded line that cannot forge a second workflow
            # command.
            print(
                f"::warning::{DROP_LOG['prose']} {finding.location()}:"
                f" {finding.message}"
            )
        elif finding.dropped:
            print(
                f"  {DROP_LOG[finding.dropped]}"
                f" {finding.location()}: {finding.message[:120]}"
            )
    print(
        f"Adjudicated: {counts['blind']} blindness claim(s) rerouted,"
        f" {counts['padding']} padding rejection(s),"
        f" {counts['disclaimer']} self-disclaiming finding(s) dropped,"
        f" {counts['prose']} prose-only disagreement(s) dropped,"
        f" {counts['duplicate']} identical duplicate(s) removed,"
        f" {counts['anchor']} unresolvable anchor(s) downgraded,"
        f" {counts['unverified']} anchor(s) left unchecked in restored"
        f" paths, {counts['normalised']} message(s) normalised."
    )
    if counts.get("space"):
        print(
            f"::warning::{counts['space']} finding(s) exceeded the"
            f" {FINDING_LIMIT}-finding cap or the {BODY_LIMIT}-character"
            " comment budget and are NOT on the pull request"
        )
    print(f"Comment body: {len(kept)} finding(s), {size} characters.")


def metrics(argv: list, kept: list, counts: dict, size: int) -> int:
    """Append the numeric metrics, and warn on a longer-but-emptier run."""
    notes = _flag(argv, "--notes")
    if notes and os.path.exists(notes):
        with open(notes, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        if text.strip():
            # `| ` on every line. The runner strips leading whitespace before
            # testing for `::`, so indenting is not enough: a note beginning
            # `::add-mask::` or `::error::` would RUN as a workflow command,
            # and the reviewer writing these notes is reading the pull
            # request under review.
            print("\nReviewer notes (kept off the pull request):")
            for line in text.splitlines():
                print(f"| {line}")

    prev_chars, prev_findings = previous_stats(_flag(argv, "--previous"))
    regression = int(
        prev_findings >= 0 and size > prev_chars and len(kept) < prev_findings
    )
    if regression:
        print(
            f"::warning::this review is longer than the one it replaces"
            f" ({size} vs {prev_chars} characters) while reporting fewer"
            f" findings ({len(kept)} vs {prev_findings})"
        )

    target = _flag(argv, "--metrics")
    if target:
        blockers = sum(1 for f in kept if f.severity == "BLOCKER")
        with open(target, "a", encoding="utf-8") as handle:
            for key, value in (
                ("REVIEW_FINDINGS", len(kept)),
                ("REVIEW_BLOCKERS", blockers),
                ("REVIEW_RISKS", len(kept) - blockers),
                ("REVIEW_PADDING_REJECTED", counts["padding"]),
                ("REVIEW_BLIND_REROUTED", counts["blind"]),
                ("REVIEW_ANCHOR_DOWNGRADED", counts["anchor"]),
                ("REVIEW_ANCHOR_UNVERIFIED", counts["unverified"]),
                ("REVIEW_SELF_DISCLAIMED", counts["disclaimer"]),
                ("REVIEW_PROSE_REJECTED", counts["prose"]),
                ("REVIEW_DUPLICATES", counts["duplicate"]),
                ("REVIEW_SCHEMA_REJECTED", counts["schema"]),
                ("REVIEW_UNSAFE_REJECTED", counts["unsafe"]),
                ("REVIEW_MESSAGE_NORMALISED", counts["normalised"]),
                ("REVIEW_NO_VERDICT", counts["no_verdict"]),
                ("REVIEW_DROPPED_FOR_SPACE", counts.get("space", 0)),
                ("REVIEW_CHARS", size),
                ("REVIEW_PREV_CHARS", prev_chars),
                ("REVIEW_PREV_FINDINGS", prev_findings),
                ("REVIEW_REGRESSION", regression),
            ):
                handle.write(f"{key}={value}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
