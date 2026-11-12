#!/usr/bin/env python3
"""Turn the reviewer's structured findings into the comment body.

    review_output.py --findings <file> --manifest <file> --base <rev>
                     --out <file> [--sections <file>]
                     [--previous <file>] [--metrics <file>]
                     [--head <sha>] [--lane <A|B|C>]
                     [--coverage-read N] [--coverage-total N]
                     [--summary <text>] [--restored "<paths>"]

`--findings` names a JSON file holding `findings` and the string arrays
`ARRAYS` names -- three keys -- written by review_text.py from the
`structured_output` of the CLI's terminal `result` event. It has already
been validated against `claude/review-schema.json` by the CLI, which refuses
the model's tool call and makes it try again until the object conforms. ALL
THREE KEYS ARE REQUIRED THERE, so a review that recorded no evidence is a
malformed response the CLI sends back rather than a weak one this program
apologises for.

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
     The only thing tying a review to a commit used to be an invisible HTML
     comment. The posted comment's own timestamp says when it was written,
     never which commit it read.
 14. A DISAGREEMENT BETWEEN TWO PIECES OF PROSE IS NOT A FINDING -- see
     `prose_only`. Nothing it describes can change behaviour, so unlike
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

THE EVIDENCE, AND THE ONE CASE WHERE IT IS PUBLISHED. `notes` is the
reviewer's account of what it checked and found sound. It is printed to the
job log on every run, and on a CLEAN VERDICT -- nothing shown and nothing
adjudicated away -- it is ALSO rendered into the comment. That is a fifth
measured complaint. A review of a four-file change posted `lane=B findings=0
read=4/4` in 385 characters whose whole body was the one sentence "No blocking
findings in the 4 of 4 files opened." The verdict was correct, and a correct
clean verdict with no evidence is indistinguishable from a review that never
ran.

~~A `Bash` WRAPPER CARRIED IT~~, appending one line per note to a file
nothing validated. SUPERSEDED: two rounds of prompt wording and one round of
publishing the notes each failed to make the model write any, and the
telemetry said why -- a six-turn run that opened every file, ended
`terminal_reason: completed` with a 1M window barely touched, and recorded
nothing. The only output the model was OBLIGED to produce was `findings`, so
the evidence was the one part it could decline for free. It is a required
property of the validated object now, and the wrapper, its bounds and its
tool grant are gone. The containment those bounds existed for did not move:
it was always duplicated in `clean_items`, which is now the only witness.

WHERE THERE ARE FINDINGS, NOTHING CHANGES and no note reaches the comment.
The tick complaint above is about PADDING a review that already carries
content; a clean verdict is the one case where the evidence IS the content,
and the two are not in tension. See `clean_items`, `notes_section` and
`fit_notes`.

AND A CLEAN VERDICT WITH NO NOTE IS NOT PUBLISHED AS CLEAN. Publishing the
evidence made the silence visible and nothing acted on it: measured across
every review posted by the 4.9 reviewer, two of four clean verdicts recorded
no note at all, including two consecutive runs over the same one-line diff
where the first recorded one and the second recorded none. The tick is the
assurance, so `header` withholds it and says what the review established
instead. See `header`'s `proved` branch.

WHAT THE CHANGE DEPENDS ON AND THE REVIEW CANNOT CHECK goes in a third
required array, `prerequisites`, which renders on EVERY verdict rather than
on the clean one alone. It is a condition outside the diff -- the
organization secret a new job reads -- and it is neither a defect nor
something examined and found sound, so it had no field and the model
dropped it: on one measured nine-repository change the previous reviewer
raised one on four of six reviews and this one on none, and it was the
condition the whole change hung on.

IT HAS NO EMPTY FORM. An empty array renders nothing and is read off
`REVIEW_PREREQUISITES`, because a sentence invented out of the model's
silence is an assertion this program is not entitled to make -- see
PREREQUISITE_LABEL, and `prerequisites_section`, which tests the PUBLISHED
list and so meets a wholly-refused array as an empty one.

~~A `limits` array travelled beside it~~, for what the reviewer read and
could not settle. BUILT AND WITHDRAWN BEFORE RELEASE, measured on the same
six reviews: prerequisites appeared in four of them and a limit in one,
which was half a restatement of the coverage `review_coverage.py` measures
better. A field with the weaker evidence, and no way to tell its filler
from its content, is not one to ship.

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

import review_coverage
import review_io

USAGE = (
    "usage: review_output.py --findings <file> --manifest <file> --base <rev>\n"
    "                        --out <file> [--sections <file>]\n"
    "                        [--previous <file>] [--metrics <file>]\n"
    "                        [--head <sha>] [--lane <A|B|C>]\n"
    "                        [--coverage-read N] [--coverage-total N]\n"
    '                        [--summary <text>] [--restored "<paths>"]'
)

# The severities the schema declares. Re-stated rather than imported so this
# program is the second witness to the CLI's enum rather than a consumer of
# the same assertion.
SEVERITIES = ("BLOCKER", "RISK")

# A SCANNING AID ON A LINE THAT ALREADY EXISTS, not a line of its own. The
# 4.8.0 work removed the per-check tick lines because they were zero-action
# filler -- 29 to 32 of them in a measured pair, each restating that
# something was fine -- and that stays removed. What went with them was the
# ability to sort a comment into issues and non-issues at a glance, which is
# a different thing and is worth one character per finding.
#
# The severity WORD stays beside the marker deliberately: the word is what a
# screen reader announces and what `rg '\*\*BLOCKER\*\*'` matches, and the
# marker is for the eye. Dropping either one costs a reader who needs it.
#
# Keyed on SEVERITIES, so a tier added to the schema without a marker raises
# a KeyError in `line_out` rather than rendering a bullet with no marker.
SEVERITY_MARK = {"BLOCKER": "❌", "RISK": "⚠️"}

# The clean verdict, and ONLY the genuine one. "No finding survived
# adjudication" and "produced no structured output" are deliberately
# unmarked: both report that nothing was established, and a tick on either
# reads as a pass for a review that did not happen.
CLEAN_MARK = "✅"

# Prerequisites are neither broken nor proved, so neither ❌ nor ✅ fits and
# ⚠️ is taken by RISK. A key: something that must be held for the change to
# work. The mark leads the paragraph rather than a list item -- see
# `notes_section` for why a bullet is not an option here.
PREREQUISITE_MARK = "🔑"

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
#
# IT BOUNDS ONE MATCH AND NOTHING ELSE, and the comment here used to read as
# though it bounded the rule. It does not: `re.search` is free to give up at
# one offset and RE-ANCHOR at the next, so a sentence whose primary claim is
# about code still matched on a trailing prose-versus-prose clause. See
# PROSE_PAIR, which closes that by refusing to be a substring at all.
CLAUSE = r"(?:(?!\band\b|\bor\b)[^.;:!?,]){0,40}?"

# A leading determiner, so "The comments contradict the docstring." can be
# required to be the WHOLE message without the article defeating it.
PROSE_LEAD = r"(?:the |a |an |this |that |its |these |both |two )?"

# Mechanism 14. A finding whose two disagreeing parties are BOTH prose.
#
# Measured 2026-10-29: a whole review whose entire output was one of these.
# "The boundary comment on <resource> (and the one near line 40) still says
# the caller reloads its configuration after start-up, which this PR marks
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
#     this rule recognises, so there is nothing to infer. PROSE_PAIR.
#  2. THE SECOND PARTY IS `each other`, which names nothing, so the SUBJECT
#     has to carry both parties by itself -- a prose noun that OPENS its
#     clause with nothing conjoined into it. "the comments now contradict
#     each other" qualifies. PROSE_SELF_PAIR.
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
# match deletes a real finding where nobody sees it. Both branches DROP,
# like CONVENTION and SELF_DISCLAIM, so both are written to miss.
#
# ===========================================================================
# WHY BRANCH 1 IS A `fullmatch` AND BRANCH 2 IS A `search`. This is the
# whole correction of 2026-10-29, and the asymmetry is measured, not taste.
#
# THE DEFECT. `CLAUSE` stops one match crossing `and`/`or`/`,`; it does not
# stop `re.search` giving up and RE-ANCHORING further along the sentence. So
# a finding whose primary claim is about CODE was deleted on the strength of
# a trailing clause that happened to name two pieces of prose. Reproduced
# end to end at RISK severity, both rendering a clean verdict:
#
#   "The README's table lists three functions; the code adds a fourth, so
#    the README is inconsistent with the inline documentation too."
#   "The inline comment contradicts the docstring, which would send an
#    operator to a flag that no longer exists."
#
# The first is a COUNT this change invalidates -- the shape `pr-prompt-v2.md`
# promotes to a must-report finding. The second is that file's own canonical
# example of one. Both are in `test_review_output.sh` now, and both fail
# against the substring form.
#
# THE FIX IS POSITIONAL, NOT LEXICAL. Another veto word would have covered
# these two sentences and not the next two; requiring the match to BE the
# message covers the class. A message that is nothing but "these two
# comments disagree" has nowhere to put a code party or a consequence, so
# the drop is safe by construction; a message with room for one is not this
# rule's to judge.
#
# AND IT IS APPLIED TO BRANCH 1 ONLY, because branch 2 cannot take it. The
# one measured true positive this mechanism exists for is branch 2, and its
# match spans 43 of 250 characters -- 17% -- with the other 83% being the
# setup that says WHICH comments and WHY. Anchoring branch 2 would not
# narrow it, it would switch it off. Measured the same day on the fixtures
# in `test_review_output.sh`: every branch-1 match in the suite is a false
# positive and every branch-2 match is a true one.
#
# WHAT BRANCH 2 THEREFORE STILL CARRIES is the same re-anchoring hazard, in
# its `each other` spelling only: "The handler drops the token; the comments
# now contradict each other" would still be dropped. That is UNFIXED and
# deliberate rather than unnoticed -- the severity floor below is the only
# thing standing under it, and the rule is one `each other` clause wide.
# ===========================================================================
PROSE_PAIR = re.compile(
    rf"\s*{PROSE_LEAD}{PROSE_NOUN}\b{CLAUSE}\b{DISAGREE}[^.;:!?]{{0,20}}?"
    rf"\b(?:with )?(?:the |that |this |its |a |an )?{PROSE_NOUN}\b"
    r"[\s.!]*",
    re.IGNORECASE,
)

PROSE_SELF_PAIR = re.compile(
    rf"(?:^|[,;:] )(?:so |and )?(?:the |these |both |two )?{PROSE_NOUN}\b"
    rf"{CLAUSE}\b{DISAGREE}[^.;:!?]{{0,20}}?"
    r"\b(?:each other|one another|themselves)\b",
    re.IGNORECASE,
)


def prose_only(message: str) -> bool:
    """Both disagreeing parties are prose, and nothing else is being said.

    `fullmatch` for the named-pair branch and `search` for the `each other`
    branch -- see the block above for why those are not the same call.
    """
    return bool(PROSE_PAIR.fullmatch(message) or PROSE_SELF_PAIR.search(message))


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

# The per-note bound, witnessed here and declared to the model in
# `review-schema.json`, for the reason SEVERITIES and MESSAGE_LIMIT are: a
# bound only the CLI's validator knows about is one this program cannot
# witness. Carried over unchanged from the retired `review-note` wrapper.
NOTE_LIMIT = 500

# How many notes may be rendered or printed, the second witness to the
# schema's `maxItems`. NOT A FRESH NUMBER: the wrapper bounded the notes
# FILE at 65,536 bytes, which is 130.8 notes at the per-note maximum plus
# its newline, rounded down. Not the count the wrapper ADMITTED -- it
# tested the size before appending, so the 131st still fitted -- the
# ceiling its bound implied. The channel moved; the ceiling did not.
NOTE_COUNT_LIMIT = 130

# The bounds on `prerequisites`, witnessed here as the two above are.
#
# NOT THE NOTE BOUNDS, because this renders on EVERY comment where a note
# renders on a clean verdict alone, and `assemble` makes room by dropping
# FINDINGS -- never a disclosure section. So the count is what the comment
# can carry beside the findings, MEASURED AGAINST ESCAPED TEXT: a
# 250-character clause naming a path, a backticked symbol and a version
# renders at 271, because `escape_markdown` adds a backslash per special.
#
# THREE, AND THE SWEEP THAT SETS IT. `MESSAGE_LIMIT` is 2000 where the
# schema ASKS for 400, so the bound is set at the message length where
# displacement starts rather than at the aim: at 500 characters a message,
# five findings and three items compose to 3,782 with nothing withheld and
# a fourth item drops one. At the 400 aim the same three cost 3,282 and
# five items still fit. ~~Two~~ was this bound while a `limits` array
# shared the budget; one array, so it is re-measured rather than inherited.
PREREQUISITE_LIMIT = 250
PREREQUISITE_COUNT_LIMIT = 3

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

# The fence a DISCLOSURE SECTION's text is rendered inside. Named rather than
# spelled twice: a second spelling of the delimiter is a second thing to keep
# in step. ~~`clean_items` has to refuse what would close it~~ SUPERSEDED:
# the notes section is no longer fenced, so no note can close anything.
FENCE = "```"

# Every character a note could spend as markdown, escaped one for one: the
# classic Markdown set, plus what GitHub added for tables, raw HTML, entities
# and strikethrough. Every occurrence is escaped, not only one at the start
# of the line, so nothing turns on WHERE in a note a character sits.
MD_SPECIALS = re.compile(r"([\\`*_{}\[\]()#+.!|<>&~=-])")

# The heading the evidence renders under on a clean verdict. It says what the
# reviewer CONCLUDED, not that it looked: "Checked" alone reads as a list of
# files opened, which `read=R/T` already measures and measures better.
NOTES_LABEL = "Checked and found sound"

# The heading the prerequisites render under. THERE IS NO EMPTY FORM, and
# ~~`PREREQUISITE_NONE` published one~~: "the change depends on nothing
# outside this diff" is an AFFIRMATIVE ALL-CLEAR this program made up out
# of the model's silence -- and `prerequisites_section` tests the PUBLISHED
# list, so an array whose every entry was refused rendered that sentence
# directly above "2 prerequisites were refused". The measured failure this
# field exists for is a reviewer that did not name the secret the change
# hung on; an all-clear there is worse than the silence it replaced.
# `REVIEW_PREREQUISITES` is how none is told from a dropped field, which is
# the job `REVIEW_NOTES_RECORDED` already does for the notes.
PREREQUISITE_LABEL = "Must be true outside this change"

# Every string array the response carries, in the order `load` reports them.
# Named once: three sites used to spell `notes` and would each have had to
# learn the second.
ARRAYS = ("notes", "prerequisites")

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
    "--previous",
    "--metrics",
    "--head",
    "--lane",
    "--coverage-read",
    "--coverage-total",
    "--truncated",
    "--summary",
    "--restored",
)


def counter_flag(argv: list, name: str) -> str:
    """A non-negative integer from `--name`, or "0" having said why.

    THE MARKER IS THE MACHINE-PARSED RECORD and every other number in it is
    checked before it is written. A malformed value would land verbatim in
    an HTML comment something later parses as digits, failing as a silently
    unreadable field rather than an error. Today's one caller guards it
    upstream, which is a property of that caller, not of this program.

    Same shape as `review_io.checked_budget`: complain on stderr and fall
    back to the value that means "none" rather than crash a review.
    """
    value = _flag(argv, name, "0")
    if value.isdigit():
        return value
    print(f"{name} must be a non-negative integer, got {value!r}", file=sys.stderr)
    return "0"


def manifest_rows(path: str) -> dict:
    """{repo path: (status, patch token)} from the manifest."""
    return {row[1]: (row[0], row[2]) for row in review_io.read_manifest(path)}


def supply_counts(rows: dict, restored: tuple) -> tuple:
    """(rows that got a patch, rows that could be opened at all).

    THE DENOMINATOR IS OPENABLE ROWS, the same population `read=R/T`
    divides by, because the marker puts the two side by side and invites
    the comparison. Counted over ALL manifest rows instead, a pull request
    touching thirty files of which ten are images renders
    `supplied=20/30 read=20/20`: a complete review that reads as a third of
    the change never reaching the reviewer.

    `review_coverage.openable` is IMPORTED rather than restated, so the two
    numbers cannot drift apart. Both come from the manifest this run was
    handed rather than the filter's log, because the manifest IS what the
    reviewer saw -- and a row with a patch path is always openable, so the
    first number is a subset of the second by construction.
    """
    openable = [
        (path, token)
        for path, (status, token) in rows.items()
        if review_coverage.openable(status, token, path, restored)
    ]
    return sum(1 for _, token in openable if token not in REASONS), len(openable)


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
    if token == "-" and status == review_io.REMOVED:
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
        """The finding as it will appear in the comment body.

        The marker precedes the severity word rather than replacing it; see
        `SEVERITY_MARK` for why both are there.
        """
        mark = SEVERITY_MARK[self.severity]
        return f"- {mark} **{self.severity}** `{self.location()}` — {self.message}"


def normalise(message: str) -> str:
    """A message reduced to what it says. An identity test, nothing more."""
    return NORMALISE.sub(" ", message.lower()).strip()


def raw_array(document: dict, key: str) -> list:
    """The response's `key` array, uninspected, or [] having said why.

    The schema requires all three, so a missing or mistyped one is the two
    witnesses disagreeing about an object the CLI validated. It reads as a
    measured empty rather than as an unmeasured run, and it says so on
    stderr: a disagreement that produced an identical comment to a
    conforming empty array is one nobody would ever investigate.
    """
    value = document.get(key)
    if isinstance(value, list):
        return value
    # THE NOTES CLAUSE IS KEPT, and it is not decoration: `notes` is the
    # array whose absence costs the comment its tick, and this message was
    # the only thing saying so. ANY OTHER ARRAY, PRESENT OR FUTURE, gets
    # the general wording -- which is right for one that is merely missing
    # and would be wrong for a second array with a consequence of its own.
    cost = (
        ", so this run recorded no evidence"
        if key == "notes"
        else ", so the two validations disagree"
    )
    print(
        f"review_output: the response carries no `{key}` array; the schema"
        f" requires one{cost}",
        file=sys.stderr,
    )
    return []


def load(path: str) -> tuple:
    """(findings, {reason: count} refused, True when supplied, raw arrays).

    The file is review_text.py's output: the CLI's `structured_output`, or
    nothing when the run produced none. A missing file, an unreadable one,
    something that is not an object, or an object with no `findings` array
    all mean the same thing -- nothing was adjudicated -- and the third
    element says so. That is a FACT about the run, where the heuristic it
    replaces ("no finding parsed, no verdict line, and some stray text") was
    an inference from how prose happened to fail.

    THE ARRAYS COME BACK RAW, uninspected, because two callers want
    different things from them: `clean_items` decides what may be rendered,
    and the job log prints what the model wrote. One that is not an array is
    an empty one -- see `raw_array` -- and `header` already withholds the
    tick from a run that recorded no evidence.

    A DICT RATHER THAN A RETURN SLOT PER ARRAY. `notes` and `prerequisites`
    are one family and every caller takes them by name, where a tuple of
    two lists and a dict is the transposition hazard `Tally` is
    keyword-only for. It also costs nothing when the third comes back.

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
    nothing: tuple = (
        [],
        dict.fromkeys(REFUSALS, 0),
        False,
        {key: [] for key in ARRAYS},
    )
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
    except OSError:
        return nothing
    if not raw.strip():
        return nothing
    try:
        document = json.loads(raw)
    except ValueError as exc:
        print(f"review_output: the findings file is not JSON: {exc}", file=sys.stderr)
        return nothing
    if not isinstance(document, dict) or not isinstance(document.get("findings"), list):
        print(
            "review_output: the findings file carries no `findings` array",
            file=sys.stderr,
        )
        return nothing

    arrays = {key: raw_array(document, key) for key in ARRAYS}

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
    return findings, refused, True, arrays


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
            and prose_only(finding.message)
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

    `supplied`, `rows` and `truncated` are about FILES, not findings, and
    they are here because the marker has to carry all of them and a reader
    could not previously tell files from findings at all. See `marker`.
    """

    shown: list
    adjudged: int
    recorded: int
    space: int
    read: str
    total: str
    supplied: int = -1
    rows: int = -1
    truncated: str = "0"
    # NOTES THE RUN RECORDED, published or not -- the clean verdict's only
    # evidence, and zero withholds the tick. ~~-1 for "the caller did not
    # say"~~: no construction site produced it. `build` passes a measured
    # count always, and a response with no `notes` array reads as zero.
    proved: int = 0


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
        if tally.proved == 0:
            # NOT the clean header, for the same reason as the two above:
            # it reports a conclusion nothing in the comment supports. The
            # reviewer read files and recorded none of it, so the only
            # honest statement is that the review proved nothing -- and the
            # mark is withheld because a tick is the assurance itself.
            return (
                f"**No findings, and nothing recorded as checked{note}.**"
                " This review is not evidence that the change is sound."
            )
        clean = f"{CLEAN_MARK} **No blocking findings{note}.**"
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

    MECHANISM 13. WHY THIS FUNCTION EXISTS, and the history matters
    because two designs were tried before the current one. The comment used
    to be EDITED IN PLACE on every push, and GitHub renders an edited
    comment at its ORIGINAL creation position and under its ORIGINAL
    timestamp. Measured 2026-10-29: a current review, updated at 16:13,
    displayed to every reader as a comment dated sixteen days earlier.
    ~~A delete-and-repost design replaced it~~ and was rejected in turn,
    because it bought an honest timestamp by destroying the record of what
    earlier reviews said.

    The workflow now POSTS A NEW COMMENT on every run and leaves every
    earlier one standing, so each review keeps its own true creation time
    and thread position and remains the record of the commit it reviewed.

    THAT MAKES THIS LINE MORE LOAD-BEARING, NOT LESS. A thread now holds
    several reviews at once, so a reader needs each one to say which commit
    it describes; a timestamp says when a comment was POSTED, never what
    was read to produce it.

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
    absent -- anything running outside Actions -- the line renders exactly
    as it does with it, minus the link. Note that under Actions it is set
    on EVERY job, the test suite included: `test_review_output.sh` clears
    it deliberately rather than inheriting it, because a fixture that reads
    the runner's own repository asserts a different thing in CI than it
    does on a laptop. A reader
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


def clean_items(value, count_limit: int, length_limit: int) -> tuple:
    """(the items that may be rendered, how many were refused).

    THE ONE CONTAINMENT PATH FOR EVERY STRING ARRAY the model sends --
    `notes` and `prerequisites` -- with the bounds passed in because only
    those differ between them. Written for notes and generalised unchanged:
    nothing below reads an item's meaning, only its text.

    `value` is one of those arrays. An item is MODEL TEXT written by a
    model that has just read an untrusted diff, so it crosses the same
    boundary `build_verdict` holds for a finding's message, with the same
    split between collapsing what has a benign reading and refusing what
    does not:

    * `<!--` OR `-->` REFUSES THE NOTE, exactly `MARKER_DELIMS`, exactly
      `build_verdict`'s rule. The state marker is an HTML comment and
      `previous_stats` reads it out of the RAW body with a regex, so a note
      carrying one forges the measurement the regression detector compares
      against. Nothing is gained by collapsing it, because the forgery is
      inline. A FENCE NEVER PROTECTED THIS and could not have: a regex over
      the raw body does not see one.
    * ~~A TRIPLE BACKTICK REFUSES THE NOTE, because the section renders
      inside a fence it would close.~~ SUPERSEDED: each note is an escaped
      paragraph, so a backtick is text like any other. The rule cost the
      reviewer a failed tool call for quoting a fenced block it had just
      read.
    * AN ITEM THAT IS NOT A STRING REFUSES, and so does one over
      `length_limit` -- the second witness to the two bounds the schema
      declares. The length is measured on the RAW string, before any
      collapsing, because that is the string the schema measured.
    * EVERY OTHER CONTROL CHARACTER IS COLLAPSED to a space, as in a
      message. A newline inside a note is one of these now rather than a
      note boundary, which is the one behaviour the array changed: the
      channel used to be a file, so a line break ENDED the note and the
      remainder became a note of its own, unmeasured against `NOTE_LIMIT`.

    ANYTHING THE SCHEMA ALREADY FORBIDS IS A REFUSAL, NOT A SKIP -- a note
    that is not a string, one that collapses to nothing, and every item
    past `count_limit`. Each is this program and the CLI disagreeing
    about an object the CLI validated, and a disagreement that published
    nothing and counted nothing is one nobody would ever see. ~~A blank was
    silently dropped~~, which was right while `review-note` could not write
    one and is not right now that the model supplies the array itself.

    EVERY REFUSAL HERE IS SILENT TO THE MODEL, which the wrapper's
    non-zero exit was not. The prompt therefore has to carry what a refusal
    COSTS -- a run whose every note is refused publishes as having
    established nothing -- because nothing in the turn will tell it.

    A refusal is counted and disclosed in the section, which is the
    accounting every other withholding in this program goes through.
    """
    if not isinstance(value, list):
        return [], 0
    notes, refused = [], 0
    for index, item in enumerate(value):
        if index >= count_limit:
            refused += 1
            continue
        # ONE BRANCH PER CAUSE, not one per condition. These two were an
        # `or`, which made five causes into four sites and left the suite's
        # count tripwire unable to say how many the warning owes a clause.
        if not isinstance(item, str):
            refused += 1
            continue
        if len(item) > length_limit:
            refused += 1
            continue
        if any(delim in item for delim in MARKER_DELIMS):
            refused += 1
            continue
        clean = " ".join(CONTROL_CHARS.sub(" ", item).split())
        if clean:
            notes.append(clean)
        else:
            refused += 1
    return notes, refused


def prerequisites_section(items: list, refused: int):
    """The prerequisites as a comment row, or None when there are none.

    `notes_section`'s rendering -- an escaped paragraph per item and a tail
    naming what was refused -- over the other array. AN EMPTY ARRAY RENDERS
    NOTHING: see PREREQUISITE_LABEL for why there is no empty form, and note
    that this tests the PUBLISHED list, so a wholly-refused array reaches
    here empty and must not read as one the model left empty.

    ~~It took a label and a noun~~ while `limits` shared it. One caller, so
    both are the constants above again: a parameter serving one argument is
    a thing to keep in step for nothing.
    """
    blocks = [f"{PREREQUISITE_MARK} {escape_markdown(item)}" for item in items]
    if refused:
        was = "was" if refused == 1 else "were"
        noun = "prerequisite" if refused == 1 else "prerequisites"
        blocks.append(
            f"-- {refused} {noun} {was} refused as text this comment"
            " cannot carry. See the job log."
        )
    if not blocks:
        return None
    return (PREREQUISITE_LABEL, "\n\n".join(blocks), True)


def escape_markdown(text: str) -> str:
    """`text` as literal prose in a markdown paragraph.

    A note is MODEL TEXT written after reading an untrusted diff, and it is
    now rendered rather than fenced, so this is what stands between that text
    and the comment's structure. Every character `MD_SPECIALS` names gets a
    backslash -- heading, list, blockquote, table, link, image, HTML tag and
    emphasis all need one of them, and a backslash before any ASCII
    punctuation is literal in CommonMark, so over-escaping is invisible to
    the reader and costs only length.

    UNCONDITIONAL, NOT POSITIONAL, which is the whole argument for it over a
    rule that escapes `#` and `-` only at the start: a one-line note has no
    second line to underline a heading or delimit a table, but reasoning
    about position is how escaping gets a case wrong. Nothing here depends on
    where a character sits.

    IT IS NOT A CODE SPAN, deliberately. Wrapping the note in backticks would
    contain it just as well and would not WRAP at a long token -- a path, a
    SHA, a URL -- which is the complaint this rendering exists to answer.

    WHAT IT CANNOT REACH, measured through GitHub's own renderer: the mention,
    reference, autolink, emoji and MATH filters run AFTER markdown escaping is
    resolved, so `@user`, `#1`, `GH-1`, a bare URL, a 40-hex SHA and `:shipit:`
    all still linkify or render. Markdown-syntax links and images are blocked;
    those filters are not, and no escaper here can block them. `line_out`
    interpolates a finding's message with no escaping at all, so this path is
    the more contained of the two.

    `\\` is in the set, so a trailing backslash cannot neutralise the escape
    on the character after it. One `re.sub` pass, so no escape is re-escaped.
    """
    return MD_SPECIALS.sub(r"\\\1", text)


def notes_section(shown: list, withheld: int, refused: int):
    """The clean verdict's evidence row: what was checked, and what is missing.

    ~~AN EMPTY LIST STILL RENDERS~~, under this heading, saying that the
    clean verdict carried no evidence. SUPERSEDED: the statement moved to
    the headline, which is where a reader who scans one line of a comment
    meets it, and where it can withhold the tick as well as explain it. A
    section headed "Checked and found sound" whose only line said nothing
    was checked also contradicted its own label, and contradicted a
    headline that no longer calls such a verdict clean.

    What is unchanged is that a reviewer recording nothing must not post
    the comment of one that recorded six checks. `header` makes that
    distinction now; see its `proved` branch.

    NONE IS NOT THE SAME AS NOTHING TO SAY. Notes withheld for the body
    budget and notes refused as unsafe text are both disclosures this
    section owes even with no note left to show, so the tail alone still
    renders. Only a run with no note, no withholding and no refusal
    returns None.

    ~~EACH NOTE IS A LINE INSIDE A ```text FENCE.~~ SUPERSEDED: a fence does
    not wrap, so a note longer than the reader's column ran off the right
    edge. Each note is now its own PARAGRAPH with its text escaped -- see
    `escape_markdown`. The fence did contain mentions and autolinks; what it
    never contained is the state marker, which `previous_stats` reads out of
    the raw body with a regex that cannot see a fence.

    ~~A LIST ITEM~~ was the first form of this and is wrong: GitHub's
    task-list filter runs on the RENDERED item text and ignores backslash
    escapes, so a note opening `[ ]` or `[x]` became a checkbox and those
    characters were DELETED from the evidence the tick rests on. A paragraph
    wraps identically, keeps `\\[ \\]` literal, and needs no separator before
    the tail. Do not restore the bullet.

    EACH PARAGRAPH LEADS WITH `CLEAN_MARK`, which is what a bullet was wanted
    for -- a column the eye can run down -- without a list marker for the
    task-list filter to key on. A mark cannot be first on a LIST ITEM either:
    `- ✅ [ ] x` would be safe, but the rule above is about not relying on
    where that filter looks.
    """
    blocks = [f"{CLEAN_MARK} {escape_markdown(note)}" for note in shown]
    tail = []
    if withheld:
        noun = "note" if withheld == 1 else "notes"
        tail.append(f"{withheld} further {noun} withheld for the comment's size")
    if refused:
        noun = "note was" if refused == 1 else "notes were"
        # ~~"refused for text that would forge the comment's own
        # structure"~~, with "Every note is in the job log." after it.
        # CORRECTED: `clean_items` refuses on FIVE grounds and only one is
        # a forgery; `log_items` cannot print three of them, so the promise
        # was false in exactly the case a reader would follow it.
        #
        # IT NAMES THE CLASS, NOT THE CAUSES. An enumeration here is a
        # fourth copy of `clean_items`' branches that nothing keeps in step
        # -- this sentence has now gone stale twice, once per round of
        # widening. `clean_items` is the list; this says only that the note
        # did not conform and where to look.
        tail.append(f"{refused} {noun} refused as text this comment cannot carry")
    if tail:
        blocks.append("-- " + "; ".join(tail) + ". See the job log.")
    if not blocks:
        return None
    return (NOTES_LABEL, "\n\n".join(blocks), True)


def fit_notes(notes: list, refused: int, kept: list, sections: list, render) -> tuple:
    """(body, the notes it carries), trimmed to BODY_LIMIT. Clean verdicts only.

    THE SAME SHAPE AS `assemble`, and for the same reason: what a section
    costs is what the COMPOSED BODY measures, never arithmetic over the
    pieces. The header, the anchor, the disclosure sections and the marker
    are all variable here -- a `--summary` the workflow computes, an
    excluded-paths list that can run to several lines -- so a fixed
    character allowance for notes would be a number nobody measured, right
    until the run where it was wrong. The budget is simply what BODY_LIMIT
    has left once everything else in this particular comment is composed.

    A NOTE IS DROPPED WHOLE, NEVER SHORTENED, which is `assemble`'s rule
    for a finding. Half a sentence of evidence is worse than one fewer
    piece of evidence and a count saying so.

    THE CHEAP PREFIX CUT IS NOT AN OPTIMISATION, IT IS WHAT BOUNDS THE
    LOOP. `clean_items` passes up to NOTE_COUNT_LIMIT notes, so a run of
    one-character ones would otherwise compose a 4,000-character body a
    hundred-odd times. No note beyond the first BODY_LIMIT characters can
    fit in a BODY_LIMIT body, so cutting there changes no outcome.

    `not shown` ends it rather than `len(shown) <= 1`: unlike a finding, a
    note is not the review's subject, so there is nothing a comment must
    overrun its budget to keep. The section then renders the withholding
    count on its own, and the headline keeps the tick -- the run DID record
    evidence, and losing it to the budget is not the same failure as never
    writing any. See `header`.
    """
    shown, used = [], 0
    for note in notes:
        used += len(note) + 1
        if used > BODY_LIMIT:
            break
        shown.append(note)
    while True:
        row = notes_section(shown, len(notes) - len(shown), refused)
        rows = sections + ([row] if row else [])
        body = compose(kept, rows, render)
        if len(body) <= BODY_LIMIT or not shown:
            return body, shown
        shown.pop()


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
    for the PREVIOUS REVIEW to measure this run against. ~~The comment to
    edit~~: nothing is edited, and `lane=` is read as well as the marker
    itself, because a skip or cancellation notice carries one too and is not
    a baseline. It was previously the model's last line, where a
    malformed one was simply unreadable and nothing noticed; `read=` in
    particular is the measurement, so it could never have come from there.

    `findings=` is what the comment CARRIES, `findings_withheld=`
    everything adjudication or the body budget removed. Without the second,
    `findings=0 blockers=0` meant both "nothing was found" and "everything
    was dropped". ~~`dropped=`~~ was the name, and because it counted
    FINDINGS while sitting beside `read=7/28` it read as the number of
    FILES withheld; two readers in turn misdiagnosed the same pull request
    from it.

    `supplied=S/T`: of `T` OPENABLE rows, `S` had a patch written. `T` is
    the population `read=R/T` divides by, which is what makes the pair safe
    to read side by side. A low `S` means the reviewer was not GIVEN the
    change; a low `R` against a high `S` means it was given it and did not
    open it.

    TWO CASES WHERE THE DENOMINATORS ONLY LOOK ALIKE, both of which arise.
    Where coverage could not be MEASURED, `read=` is a token, not a pair.
    Where the coverage step did not RUN -- an error lane, a skipped review
    -- the workflow passes `--coverage-read 0 --coverage-total 0`, and
    `read=0/0` then means "not measured", never "nothing was openable". The
    lane letter says which.

    **v4, NOT v3.** The token tracks the FIELD SET, and this release renamed
    one field and added two; one token must mean one schema, or a future
    reader parses by position and gets the wrong integer. `lane=T` omits
    `findings=` so it can never be read as a baseline.

    `truncated=N` IS WHAT STOPS `supplied=` BECOMING THE NEXT LIE. A
    truncated patch is supplied, so thirty files all cut back to their first
    hunk still render `supplied=30/30 read=30/30` -- a perfect-looking
    review of a change mostly not shown.
    """
    blockers = sum(1 for f in tally.shown if f.severity == "BLOCKER")
    # NOT `findings_...`: `previous_stats` matches `findings=(\d+)` and a
    # second field whose name ENDS in that literal would be captured
    # instead. The regex is anchored now; the name still avoids the trap.
    return (
        f"<!-- claude-review v4 lane={lane} findings={len(tally.shown)}"
        f" blockers={blockers} findings_withheld={tally.recorded + tally.space}"
        f" supplied={tally.supplied}/{tally.rows}"
        f" truncated={tally.truncated}"
        f" read={tally.read}/{tally.total} head={head} -->"
    )


def previous_stats(path: str) -> tuple:
    """(characters, findings) of the previous review this run is measured against.

    ~~The comment this run is replacing~~ -- nothing is replaced. The
    workflow appends a new comment per run and hands this the body of the
    MOST RECENT earlier REVIEW: newest id, and only a `lane=[ABC]` marker,
    so a skip, error or cancellation notice is never the baseline. See
    REVIEW_BASELINE_JQ in claude-pull-request-review.yaml.

    THE LAST MARKER WITHIN THAT BODY, NEVER THE FIRST. `compose` writes the marker
    as the final line of the body, so the real one is always last and anything
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
    # THE LOOKBEHIND IS THE FIX, not a position. The greedy
    # `[^>]*findings=` matched the LAST `findings=`-suffixed field, so a
    # name like `dropped_findings=` would hand this the wrong integer with
    # nothing failing. The class covers every separator a field name can
    # use -- `(?<![\w])` alone still accepted `dropped-findings=` and
    # `drop.findings=` -- while leaving the field free to MOVE, which an
    # anchor on `lane=\S+ ` would not. lane=T carries no `findings=` at
    # all; `found[-1]` handles it.
    found = re.findall(r"<!-- claude-review v\d+ [^>]*(?<![\w.\-])findings=(\d+)", body)
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
    # A row is (label, text) and renders inside FENCE. A third element marks
    # text that is already markdown, which `notes_section` and
    # `prerequisites_section` set because they escape their content first.
    # Every other row is model-free text from the workflow and is fenced.
    for row in sections:
        label, text, rendered = row[0], row[1], len(row) > 2 and row[2]
        parts.extend(["", f"**{label}**", ""])
        parts.extend([text] if rendered else [f"{FENCE}text", text, FENCE])
    parts.extend(["", state, ""])
    return "\n".join(parts)


def notes_body(notes: list, counts: dict, kept: list, sections: list, render):
    """The clean verdict's body, carrying its evidence -- or None, for every
    other verdict. Sets every note count on `counts` either way.

    CLEAN IS TESTED ON THE SAME TWO QUANTITIES `header` BRANCHES ON --
    nothing in the comment and nothing adjudicated away -- so the evidence
    section and the CLEAN_MARK headline cannot disagree about what a clean
    verdict is.

    THE OTHER TWO HEADLINES ARE DELIBERATELY EXCLUDED, and neither is an
    oversight. "No finding survived adjudication" is a different statement
    and must keep making it; a list of things found sound rendered beneath
    it would read as support for a verdict that was never reached, which is
    mechanism 6's mistake one level down. And a run that produced no
    structured output adjudicated NOTHING, so it has no verdict for evidence
    to support. ~~Its notes could be the model's last act before the run
    failed to produce an object at all.~~ CORRECTED: the notes ARE part of
    that object, so a run that produced none produced no notes either and
    this branch is unreachable from the evidence side.

    A VERDICT CARRYING FINDINGS IS EXCLUDED TOO, and that was re-argued on
    2026-11-07 against publishing notes whenever any exist. The
    29-and-then-32-ticks complaint is about PADDING a review that already
    carries content, and a code fence around the ticks does not change what
    they are; it would also pay the model for narrating rather than reading,
    which is the failure the no-ticks rule was written against. Low coverage
    was considered as a second trigger and rejected: it needs a threshold,
    and coverage does not predict diligence well enough
    to gate on -- one measured review opened 11 of 44 supplied files and
    produced two correct, non-obvious findings. ~~`REVIEW_NOTES_RECORDED`
    is what makes the silence measurable instead.~~ CORRECTED: the schema
    requires at least one note, so a conforming response cannot be silent
    and that metric now measures the three ways it can still read zero --
    the two witnesses disagreeing, every note refused, or no structured
    output at all. It is still written on every run.
    """
    if kept or dropped_total(counts, DISCLOSED) or counts["no_verdict"]:
        return None
    body, shown = fit_notes(notes, counts["note_refused"], kept, sections, render)
    counts["notes"] = len(shown)
    counts["notes_withheld"] = len(notes) - len(shown)
    return body


def build(argv: list, findings: list, counts: dict, sections: list, raw) -> tuple:
    """(comment body, the findings it actually carries).

    The header and the marker are rendered from whatever survives trimming
    rather than from the list this was handed: both were computed once, so a
    finding dropped to fit the byte budget stayed counted in the header, in
    the marker and in the metrics. `counts["space"]` is set to how many were
    withheld -- by the FINDING_LIMIT cap and by the body budget together.

    A CLEAN VERDICT IS RE-COMPOSED with the reviewer's notes in it -- see
    `notes_body`, which decides, and the module docstring for why.
    """
    survived = rank(findings)
    # COUNTED BEFORE THE FIRST RENDER, not inside `notes_body`. `assemble`
    # renders the header while deciding what fits, so a count set afterwards
    # reaches the headline of the clean body and not of any other -- and the
    # clean body is re-composed from it. Both must see the same number.
    #
    # HOW MANY THE RUN PRODUCED AT ALL, published or not. The other three
    # note counts are zero on every review that carries findings, so without
    # this one the fleet has no signal for the defect that prompted the
    # mechanism: on the measured run the model emitted `{"findings": []}`
    # and no evidence at all. "Published none" and "wrote none" are
    # different failures and only one is ours.
    #
    # ~~IT IS WHAT MAKES THE SILENCE MEASURABLE.~~ CORRECTED: the schema
    # requires at least one note, so a CONFORMING response can no longer be
    # silent and this count can only reach zero three ways -- the two
    # witnesses disagreeing, every note refused as unsafe or malformed, or
    # no structured output at all. It now measures those, not silence.
    notes, counts["note_refused"] = clean_items(raw, NOTE_COUNT_LIMIT, NOTE_LIMIT)
    counts["notes_recorded"] = len(notes)
    counts["notes"] = 0
    counts["notes_withheld"] = 0
    lane = _flag(argv, "--lane", "B")
    head = _flag(argv, "--head", "unknown")
    summary = _flag(argv, "--summary")
    # READ ONCE, not per render. `assemble` calls `render` again after every
    # trim, so a clock read inside it can change the body between iterations
    # and would put a different minute in the comment than the one the body
    # was measured at.
    when = time.strftime(STAMP, time.gmtime())

    def render(shown: list) -> tuple:
        """(header, anchor, marker) for exactly the findings `shown` holds.

        BOTH TOTALS ARE TAKEN FROM `counts` HERE, not hoisted into two
        locals above. They are two views of one dictionary and nothing
        between here and there may change one without the other.
        """
        # BY KEYWORD. Nine positional arguments with two adjacent ints --
        # `supplied` and `rows` -- is the silent-corruption shape `Request`
        # warns about in filter_diff.py: transposing them is not a type error.
        tally = Tally(
            shown=shown,
            adjudged=dropped_total(counts, DISCLOSED),
            recorded=dropped_total(counts, RECORDED),
            space=len(survived) - len(shown),
            # Read here rather than hoisted: unlike the clock these are
            # constant strings, so re-reading them per render cannot change
            # the body. `--truncated` is validated, not just defaulted --
            # see `counter_flag`.
            read=_flag(argv, "--coverage-read", "0"),
            total=_flag(argv, "--coverage-total", "0"),
            supplied=counts.get("supplied", -1),
            rows=counts.get("rows", -1),
            truncated=counter_flag(argv, "--truncated"),
            proved=counts["notes_recorded"],
        )
        return (
            header(tally, summary, bool(counts["no_verdict"])),
            # The runner sets this on every job; nothing passes it in.
            # Read per render rather than hoisted, unlike the clock: it is a
            # constant for the life of the process, so it cannot change the
            # body between trims. See `anchor`.
            anchor(head, when, os.environ.get("GITHUB_REPOSITORY", "")),
            marker(lane, tally, head),
        )

    body, kept = assemble(survived[:FINDING_LIMIT], sections, render)
    counts["space"] = len(survived) - len(kept)
    # `or body` is safe by construction and not a shortcut: `compose` always
    # emits the heading and the marker, so a body is never the empty string.
    return notes_body(notes, counts, kept, sections, render) or body, kept


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

    findings, refused, supplied, arrays = load(found)
    rows = manifest_rows(manifest)
    restored = tuple(_flag(argv, "--restored").split())
    counts = adjudicate(
        findings,
        rows,
        base_paths(_flag(argv, "--base", "HEAD^")),
        restored,
    )
    counts["supplied"], counts["rows"] = supply_counts(rows, restored)
    counts["duplicate"] = collapse(findings)
    counts["schema"] = refused["schema"]
    counts["unsafe"] = refused["unsafe"]
    counts["normalised"] = refused["normalised"]
    # A run that produced no object at all adjudicated nothing. A run that
    # produced `{"findings": []}` adjudicated everything and found nothing,
    # which is a verdict and must not be confused with the first.
    counts["no_verdict"] = int(not supplied)

    body, kept = build(
        argv,
        findings,
        counts,
        disclosures(argv, counts, clean_prerequisites(arrays, counts)),
        arrays["notes"],
    )

    with open(out, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(body)

    report(kept, findings, counts, len(body))
    log_arrays(arrays)
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
    note_report(kept, counts)
    prerequisite_report(counts)


def note_report(kept: list, counts: dict) -> None:
    """What became of the reviewer's notes, for the job log.

    AT MOST ONE OF THE LAST TWO LINES RENDERS, and which one has to agree
    with the headline the comment carries. ~~The clean line printed on `not
    kept` alone~~: it called the zero-note and the all-refused run clean,
    which are the two whose headline now says the review is not evidence
    that the change is sound, and on a clean verdict whose notes did not fit
    the budget it printed beside "this review is not clean." Both lines are
    gated on the test `notes_body` makes, so the log cannot call a verdict
    clean that the comment does not.

    A run that recorded nothing is reported by the headline, not here. On a
    review that carries findings the notes are kept off the comment BY
    DESIGN, so that line only says where they went -- an absent section must
    never read as evidence lost on the way.
    """
    if counts.get("note_refused"):
        # THE ONLY SITE THAT STILL ENUMERATES, and so the only one that can
        # go stale: the comment tail and the skipped line name a class now.
        # One cause per `clean_items` branch, in its order. ~~It named four
        # of five and called them all schema violations~~: `not a string`
        # was missing, and a blank note conforms to `minLength: 1` -- it is
        # refused for collapsing to nothing, which the schema cannot say.
        print(
            f"::warning::{counts['note_refused']} reviewer note(s) were not"
            f" rendered: past the {NOTE_COUNT_LIMIT}th, not a string, over"
            f" {NOTE_LIMIT} characters, an HTML comment in the text that"
            " would forge the comment's own structure, or blank once"
            " control characters are collapsed"
        )
    if counts.get("notes_withheld"):
        print(
            f"::warning::{counts['notes_withheld']} reviewer note(s) did not"
            f" fit the {BODY_LIMIT}-character comment budget and are NOT on"
            " the pull request"
        )
    # THE SAME THREE QUANTITIES `notes_body` DECIDES ON. Gating on `kept`
    # alone would call a run clean that the comment headlines as having
    # adjudicated everything away, or as having produced no verdict at all.
    clean = not (kept or dropped_total(counts, DISCLOSED) or counts.get("no_verdict"))
    if counts.get("notes_recorded") and not clean:
        print(
            f"{counts['notes_recorded']} reviewer note(s) recorded and kept"
            " off the pull request; this review is not clean."
        )
    if clean and counts.get("notes_recorded"):
        print(
            f"Clean verdict: {counts.get('notes', 0)} reviewer note(s)"
            " published as its evidence."
        )


def prerequisite_report(counts: dict) -> None:
    """What the reviewer said the change depends on, for the job log."""
    print(f"Prerequisites: {counts.get('prerequisites', 0)} recorded.")
    if counts.get("prerequisites_refused"):
        # NO ORDINAL. `{PREREQUISITE_COUNT_LIMIT}th` prints "3th" for every
        # count but 4 to 20, and the number is a constant somebody will move.
        print(
            f"::warning::{counts['prerequisites_refused']} prerequisite(s)"
            f" were not rendered: beyond the {PREREQUISITE_COUNT_LIMIT} this"
            f" comment carries, not a string, over {PREREQUISITE_LIMIT}"
            " characters, an HTML comment in the text that would forge the"
            " comment's own structure, or blank once control characters are"
            " collapsed"
        )


# The item bound each array is listed under, by name rather than by an
# `== "notes"` test: an array added to ARRAYS and not to this map raises a
# KeyError here instead of silently inheriting another array's bound, which
# is `SEVERITY_MARK`'s rule for the same reason.
ARRAY_BOUND = {"notes": NOTE_COUNT_LIMIT, "prerequisites": PREREQUISITE_COUNT_LIMIT}


def log_arrays(arrays: dict) -> None:
    """Every array the response carried, as written, for the job log."""
    for key in ARRAYS:
        log_items(key, arrays[key], ARRAY_BOUND[key])


def log_items(key: str, raw, count_limit: int) -> None:
    """Every item of one `ARRAYS` member, as written, for the job log.

    THE RAW ARRAY, not what `clean_items` passed: this is the only place a
    refused item is visible at all, and a log printing only the publishable
    ones would hide exactly the one whose wording has to change. Bounded by
    the same count the render is -- the array is model text and the job log
    is unbounded.

    WHAT IT CANNOT PRINT, IT COUNTS, so the listing reconciles against
    REVIEW_NOTES_REFUSED. ~~"the two refusals only this second witness can
    ever see"~~ was two of three: an EMPTY STRING also prints nothing,
    because `"".splitlines()` is `[]`, and it was neither listed nor
    counted -- the one item that could vanish from both.
    """
    lines, skipped = [], 0
    for index, item in enumerate(list(raw)):
        if index >= count_limit or not isinstance(item, str):
            skipped += 1
            continue
        if not item.splitlines():
            skipped += 1
            continue
        # `| ` on every line. The runner strips leading whitespace before
        # testing for `::`, so indenting is not enough: a note beginning
        # `::add-mask::` or `::error::` would RUN as a workflow command,
        # and the reviewer writing these notes is reading the pull request
        # under review. A note carrying a newline is several lines here and
        # one note to `clean_items`, which collapses it.
        lines.extend(item.splitlines())
    if not lines and not skipped:
        return
    if lines:
        # ~~"kept off the pull request"~~. They are published on a clean
        # verdict; this is every note the run recorded, including any the
        # comment refused or could not fit.
        print(f"\nReviewer {key} (every one recorded, as written):")
        for line in lines:
            print(f"| {line}")
    if skipped:
        print(
            f"\n{skipped} further item(s) in the `{key}` array were neither"
            f" listed nor published: empty, past the {count_limit}-item"
            " bound, or not a string. The output schema forbids all three,"
            " so this is the CLI's validation and this program disagreeing."
        )


def clean_prerequisites(arrays: dict, counts: dict) -> list:
    """The prerequisites that may be rendered, with their counts set.

    CLEANED HERE AND NOT IN `build`, because `disclosures` renders them and
    this is the last point before it. `notes` stays in `build` for the one
    reason given there: its count reaches the headline, which `assemble`
    renders while deciding what fits.
    """
    items, counts["prerequisites_refused"] = clean_items(
        arrays["prerequisites"], PREREQUISITE_COUNT_LIMIT, PREREQUISITE_LIMIT
    )
    counts["prerequisites"] = len(items)
    return items


def disclosures(argv: list, counts: dict, prerequisites: list) -> list:
    """Every row the comment owes: the prerequisites, the workflow's, then
    adjudication's.

    PREREQUISITES LEAD, because a condition the change depends on is a
    statement about THIS change that a reader acts on, where every row below
    is accounting about the review. It is also the only row that renders on
    a run with findings and on a clean one alike.

    IT DOES NOT RENDER WHERE NOTHING WAS ADJUDICATED, and it does not render
    empty. A run that produced no structured output produced no array
    either, and an empty array is a count rather than a sentence -- see
    PREREQUISITE_LABEL for why this program may not speak for the model's
    silence.
    """
    row = None
    if not counts["no_verdict"]:
        row = prerequisites_section(prerequisites, counts["prerequisites_refused"])
    sections = [row] if row else []
    sections.extend(read_sections(_flag(argv, "--sections")))
    if dropped_total(counts, DISCLOSED):
        sections.append(drop_section(counts))
    if counts["duplicate"]:
        sections.append(duplicate_section(counts["duplicate"]))
    if counts["unverified"]:
        sections.append(restored_section(counts["unverified"]))
    return sections


def metrics(argv: list, kept: list, counts: dict, size: int) -> int:
    """Append the numeric metrics, and warn on a longer-but-emptier run."""
    prev_chars, prev_findings = previous_stats(_flag(argv, "--previous"))
    regression = int(
        prev_findings >= 0 and size > prev_chars and len(kept) < prev_findings
    )
    if regression:
        print(
            f"::warning::this review is longer than the previous one"
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
                ("REVIEW_NOTES_RECORDED", counts.get("notes_recorded", 0)),
                ("REVIEW_NOTES", counts.get("notes", 0)),
                ("REVIEW_NOTES_WITHHELD", counts.get("notes_withheld", 0)),
                ("REVIEW_NOTES_REFUSED", counts.get("note_refused", 0)),
                ("REVIEW_PREREQUISITES", counts.get("prerequisites", 0)),
                (
                    "REVIEW_PREREQUISITES_REFUSED",
                    counts.get("prerequisites_refused", 0),
                ),
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
