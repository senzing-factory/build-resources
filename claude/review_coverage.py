#!/usr/bin/env python3
"""Measure how much of a pull request the reviewer actually opened.

    review_coverage.py <manifest.tsv> <transcript.jsonl> [--workspace DIR]
                       [--github-env FILE] [--missed-file FILE]
                       [--restored "<paths>"]

Reads the manifest the reviewer was given and the Claude Code `stream-json`
transcript of the run that reviewed it, and prints which manifest rows the
model opened and which it did not. Exits 0 whatever the coverage is: this
program measures, the workflow decides.

WHY THIS EXISTS, and why it reads the transcript rather than the review.

On 2026-10-21 a 33-file pull request carrying 2,145 changed lines of Rust was
reviewed down to a single comment about hardcoded paths in a markdown handoff
note, and the job went green. Nothing in the workflow compared what came back
against what had been handed over, so a review that opened one file and a
review that opened all of them produced the same green check.

The signal has to be OBSERVED, not reported. A model asked how much it read
answers from the same context that produced the thin review, so a self-report
is a second output of the thing under test rather than a measurement of it.

A `Read` TOOL CALL IS NOT A FILE OPENED. The call is a request; the matching
`tool_result` says whether it returned anything. A Read of a path that does
not exist, or of a binary file, comes back `is_error` with no content, and
counting it would make the gate pass on the exact condition it exists to
catch -- all the more so now that the prompt tells the model its reads are
counted, which makes an unchecked counter something to satisfy rather than
something to measure. So a path is credited only when its `tool_use.id`
appears again as a `tool_result.tool_use_id` that carried content and was not
flagged an error.

WHAT COUNTS AS COVERED. A manifest row is covered when the model opened
EITHER the patch written for it under `pr-files/` OR the file itself in the
working tree. The second half is not a concession: rows whose patch column is
`-` or `omitted` have no patch to read, and the working tree is the only
place their content exists. A row covered that way is covered properly.

WHAT IS EXEMPT, and why the denominator is not simply the row count. Some
rows cannot be opened by anything, so requiring them would make every pull
request containing one unmergeable wherever enforcement fails:

  * `removed` rows with no patch file -- a deleted file is not in the working
    tree, so no `Read` can ever succeed on it.
  * `binary` rows -- there is no patch worth reading and `Read` refuses the
    file itself.
  * rows with no patch under a path the workflow REVERTED to base content
    before the review ran -- `.claude`, `CLAUDE.md`, `.ripgreprc` and the
    rest, named by `--restored`. The reviewer is sent to the working tree for
    a row with no patch, and at those paths the working tree holds the base's
    file or no file at all, so the read it is told to make cannot succeed.
    Without this the row counts unopened and, under `fail`, there is nothing
    the author can do about it.

Those are counted and named separately rather than silently dropped.

MATCHING IS EXACT, against `--workspace`. The transcript records absolute
paths under the runner's workspace and the manifest records repo-relative
ones, so the workspace prefix is stripped from each read path and the two are
then compared whole. Suffix matching was the earlier shape and it credits the
wrong file: a path-boundary anchor stops `lib.rs` matching `mylib.rs`, and
stops nothing else -- `vendor/src/lib.rs` ends in `/src/lib.rs` and retired
the row for the real `src/lib.rs`, while any `cmd/*/main.go` retired a
repository-root `main.go`. A vendored tree is the likely trigger, being in
the default exclude_globs and therefore absent from the manifest and present
in the checkout.

A RELATIVE read path keeps the old suffix test, because there is no prefix
to strip from it and a repo-relative path recorded in the transcript must
still count. Without `--workspace` every path is treated that way, so the
program degrades to suffix matching and SAYS SO in its report.

An ABSOLUTE read path that is not under the workspace is credited to
NOTHING. It is a file under some other root -- a vendored checkout, a tool
cache -- and suffix-matching it is the defect this section describes.
Leaving it in the suffix set reinstated that defect in full: with no read
path under the workspace, EVERY row matched something and the program
reported total coverage over a review that had opened none of it.

WHEN NOTHING CAN BE MATCHED THE RESULT IS A TOKEN, NOT A NUMBER. Two
different failures both leave every row's state unknown, and neither may be
reported as a coverage of zero:

  * READS HAPPENED AND NOT ONE WAS MATCHABLE -- none stripped the workspace
    prefix and none was relative. The prefix is wrong, or the transcript
    records paths another way.
  * NO `tool_use` OR `tool_result` BLOCK APPEARS AT ALL in a transcript that
    did parse. The stream-json envelope is an undocumented interface. The
    CLI version is pinned and the installed one is checked against the pin,
    but a version that renamed either block leaves the walk below finding
    nothing: no reads, so the first case cannot fire either, and an empty
    read set reports a confident, MEASURED `0/N` over an instrument that has
    stopped working -- on 170 repositories at a floating tag, a comment on
    every pull request asserting nobody opened anything. One block of ANY
    tool name proves the vocabulary is still the one read here, after which
    zero reads really is zero.

A RUN THAT USED NO TOOLS IS NOT THE SECOND CASE, and that is why the test is
any tool block rather than any `Read`. The findings reach the comment only as
the argument of a `StructuredOutput` call, the workflow runs this program
only once review_text.py has recovered that argument, and a tool call is a
`tool_use` block -- so every transcript this program is handed carries at
least one. A transcript with none is a transcript that cannot be read.

MEASURED, 2026-10-27, because that paragraph was an argument from design and
the fixtures hand-write the block whose existence it asserts. `claude -p
--output-format stream-json --verbose --json-schema <schema>` on CLI 2.1.267,
with the model told to use no tools, emitted five events: `system`,
`rate_limit_event`, an `assistant` carrying ONE `tool_use` named
`StructuredOutput`, the matching `tool_result`, and the terminal `result`
whose `structured_output` is the object. So the claim holds for that version.
It was not re-run at the pinned 2.1.310, and the whole point of NO_ENVELOPE
is the version that changes it, so nothing below depends on it.

NOTHING THAT CANNOT BE MEASURED IS REPORTED AS UNMEASURED. Either cause above
withholds the counts only where a row's state actually depended on the
transcript. A manifest whose every row is exempt -- a binary-only pull
request -- has none: the exemptions are read off the manifest, `0 of 0
openable` is true whatever the stream looked like, and the workflow's gate
passes on a literal `0` and nothing else. Withholding there turned a green
check red and pointed its reader at the CLI pin over a change with no file to
open. The diagnosis is still printed; only the counts stay numbers. This is
also the only case in which withholding changes the gate's verdict: a
degraded run can credit no row, so wherever a row IS openable the count it
withholds is a failing one either way.

An ABSENT transcript is neither, and stays a measured zero: there is no
stream to have an envelope, and the fixture pinning that behaviour is there
to prove this program does not fail OPEN when the file is gone.

Both unmeasured cases write the four counts as the literal token
`unmeasured`, which is what the workflow writes when this program cannot run
at all and what its enforcement test reads as a non-pass. They are ANNOTATED
differently, because one is diagnosed by checking `--workspace` and the other
by checking what the pinned CLI now emits.

Manifest paths arrive C-escaped (filter_diff.py quotes backslash, tab, CR and
LF so one path cannot forge a TSV row), so they are unescaped back to the
real path before matching -- compared raw, any path containing a backslash or
a tab could never match the transcript and would be reported unread forever.

OUTPUT. A human-readable report on stdout, and with `--github-env`, four
COUNTS appended to that file:

    COVERAGE_TOTAL      manifest rows that can be opened at all
    COVERAGE_READ       rows the model opened
    COVERAGE_UNCOVERED  count of openable rows it did not open
    COVERAGE_EXEMPT     rows with nothing to open (deleted or binary)

Every uncovered row is named on stdout and in `--missed-file` with a code
saying WHAT IT WAS GIVEN and WHETHER IT TRIED -- `PATCH`, `WORKTREE`, either
with `+TRIED`. That distinction is the whole reason this program reads the
transcript twice: a row nobody opened and a row whose `Read` came back empty
are different defects with different owners, and the counts alone report
them identically. The transcript itself does not outlive the job, so a code
not emitted here cannot be recovered later.

all four being the token `unmeasured` instead whenever this run established
nothing -- either of the two cases above.

COUNTS ONLY, and `--missed-file` for the paths. That split is a fix, not a
style: the paths come from the pull request's own tree, git permits a
newline in a path, and a newline in `$GITHUB_ENV` appends an arbitrary
variable to the job environment. An earlier version of this program wrote
the path list there, having first UNESCAPED the C-quoting that filter_diff.py
applies for exactly this reason.

WHAT THIS DOES NOT MEASURE. That the model UNDERSTOOD what it opened, or that
a `Read` covered the whole file rather than its first page. Both are real
gaps. Neither is a reason to leave zero measurement in place, and the failure
this catches -- a large change where most rows were never opened at all -- is
the one that actually happened.
"""

import os
import sys
from typing import NamedTuple

import review_io

USAGE = (
    "usage: review_coverage.py <manifest.tsv> <transcript.jsonl>\n"
    "       [--workspace DIR] [--github-env FILE] [--missed-file FILE]\n"
    '       [--restored "<paths>"]'
)

# The manifest's fourth column when there is no patch file to read. They mean
# "there is no patch", for three different reasons, and only the first two
# leave the working tree as a fallback.
#
# THE PER-FILE CAP IS DELIBERATELY NOT HERE. It truncates rather than
# withholds, so its rows carry a real patch path and never reach this tuple
# -- which is the whole point of that design: a withheld patch on a
# `removed` row, or on one under a restored prefix, made `openable` False
# and took the row out of the denominator. A token for it would have to sit
# on the no-patch side and would reopen exactly that hole.
NO_PATCH = ("-", "omitted", "binary")

# The fourth-column token for a file git reported as binary, and the status
# column's token for a deletion. Both make a row unopenable; see the module
# docstring.
BINARY = "binary"
REMOVED = review_io.REMOVED

# How many missed paths reach the environment file and the PR comment. The
# rest are counted. Matches the cap the workflow already applies to its
# excluded and omitted lists, so the disclosures truncate alike.
MISSED_LIST_CAP = 20

# The option flags, each taking one value.
FLAGS = ("--github-env", "--missed-file", "--restored", "--workspace")

# What the four counts say when nothing could be matched. A fixed token, so
# it is still safe in `$GITHUB_ENV`, and the SAME token the workflow writes
# when this program cannot run -- its gate tests COVERAGE_UNCOVERED against
# "0", so anything else, this included, falls through to the non-pass branch.
UNMEASURED = "unmeasured"

# The two transcript block types this program reads. Finding one of EITHER,
# under any tool name, is what proves the envelope is still legible; finding
# none is the difference between "opened nothing" and "could not look".
TOOL_BLOCKS = ("tool_use", "tool_result")

# Why a run is unmeasured. Separate values because the two are diagnosed in
# different places -- a wrong --workspace against a CLI that moved under its
# pin -- and a single boolean sent whoever reads the job log to one of them
# at random.
NO_ENVELOPE = "envelope"
NO_MATCH = "workspace"

# The names, in the order they are written.
COUNT_KEYS = (
    "COVERAGE_TOTAL",
    "COVERAGE_READ",
    "COVERAGE_UNCOVERED",
    "COVERAGE_EXEMPT",
)


class Reads(NamedTuple):
    """What the transcript recorded about the reviewer's `Read` calls.

    Named rather than a bare tuple because `issued`, `succeeded`, `failed`
    and `unmatched` are four integers that mean entirely different things,
    and a positional mix-up between them would silently change what the
    coverage report says happened.

    `events` and `tool_events` are about the TRANSCRIPT rather than about the
    reads: how many lines parsed, and how many blocks of a type this program
    knows were in them. They are what separates a run that opened nothing
    from a transcript whose envelope this program can no longer read.

    `paths` is what RETURNED a file; `attempted` is every path a `Read` was
    issued for. A row in neither was never looked at; a row in `attempted`
    and not in `paths` was looked at and gave nothing back. Those are
    different failures with different owners -- the first is the reviewer
    under-reading, the second is a path that is not there to be read -- and
    reporting them as one number is what made a 7-of-28 review impossible to
    diagnose from the pull request it was posted on.
    """

    paths: set
    attempted: set
    issued: int
    succeeded: int
    failed: int
    unmatched: int
    events: int
    tool_events: int


def read_paths(transcript: str) -> Reads:
    """(paths successfully read, call counts) from one transcript.

    One JSON object per line. A line that does not parse is skipped rather
    than fatal: a truncated transcript should under-report coverage, which
    fails toward "not reviewed", not toward a crash that loses the review.

    The counts are (issued, succeeded, failed, unmatched) over `Read` tool
    calls. `unmatched` is the number whose result never appeared, which is
    what a HALF-changed transcript envelope would look like from here -- the
    call block still recognised, the result block not -- so it is annotated
    as a warning rather than silently read as "the model opened nothing".

    `events` and `tool_events` count the stream itself: parsed lines, and
    blocks of a type this program knows. A transcript that parsed and held
    no such block is one whose envelope has changed WHOLESALE, and it is
    unmeasured rather than empty -- see the module docstring.
    """
    requested: dict = {}
    results: dict = {}
    events = 0
    blocks = 0
    for event in review_io.json_lines(transcript):
        if event is None:
            continue
        events += 1
        blocks += _collect(event, requested, results)

    paths = {path for call, path in requested.items() if results.get(call) is True}
    # EVERY path a `Read` was issued for, whatever came back. `paths` is the
    # subset that returned a file; the difference between the two is the only
    # thing that separates "the reviewer never looked at this row" from "it
    # looked and got nothing", and until this set existed the transcript that
    # held the answer was deleted with $RUNNER_TEMP at the end of the job.
    attempted = set(requested.values())
    succeeded = sum(1 for call in requested if results.get(call) is True)
    failed = sum(1 for call in requested if results.get(call) is False)
    return Reads(
        paths=paths,
        attempted=attempted,
        issued=len(requested),
        succeeded=succeeded,
        failed=failed,
        unmatched=len(requested) - succeeded - failed,
        events=events,
        tool_events=blocks,
    )


def _collect(event, requested: dict, results: dict) -> int:
    """Record this event's `Read` calls and every tool result it carries.

    Walks the whole object rather than keying off `type`/`message.content`:
    the envelope around a tool_use block has changed shape before and a
    coverage check that silently stops finding any is worse than one that
    looks everywhere. The two block types are identified by their own `type`
    field, so the walk cannot pick up anything else.

    Calls and results are accumulated into the SAME two maps across every
    line, because a result arrives on a later line than the call it answers.

    Returns how many blocks of a type this program knows were in the event,
    counting every tool name rather than only `Read`. The caller needs that
    to tell a run which opened nothing from a transcript whose envelope it
    cannot read: in the second, finding no `Read` proves nothing at all.
    """
    found = 0
    stack = [event]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            kind = node.get("type")
            if kind in TOOL_BLOCKS:
                found += 1
            if kind == "tool_use" and node.get("name") == "Read":
                call = node.get("id")
                target = node.get("input")
                if isinstance(call, str) and call and isinstance(target, dict):
                    path = target.get("file_path")
                    if isinstance(path, str) and path:
                        requested[call] = path
            elif kind == "tool_result":
                call = node.get("tool_use_id")
                if isinstance(call, str) and call:
                    # Content AND no error flag. `not is_error` alone credits
                    # a result that carried nothing, so a schema change moving
                    # the error signal elsewhere would credit every failed
                    # read; the default has to be "nothing was returned".
                    results[call] = bool(node.get("content")) and not node.get(
                        "is_error"
                    )
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    return found


class Seen(NamedTuple):
    """Read paths, split by what can legitimately be matched against a row.

    `inside` is repo-relative and compared whole. `relative` had no prefix to
    strip and keeps the suffix test, which is the weaker of the two.
    `elsewhere` is absolute and under some other root: counted and reported,
    matched against nothing.
    """

    inside: set
    relative: set
    elsewhere: set


def workspace_split(read: set, workspace: str) -> Seen:
    """Read paths made repo-relative where they lie under the workspace.

    Both sides are normalised first: an exact comparison is defeated by a
    `./` or a doubled slash the CLI happened to record, and the failure
    would be a silent 0/N rather than an error.

    An absolute path that is not under the workspace is separated out rather
    than left in the suffix set, because the suffix set credits rows: a
    transcript of nothing but such paths made every row match and reported
    full coverage.
    """
    prefix = os.path.normpath(workspace) + "/" if workspace else ""
    inside, relative, elsewhere = set(), set(), set()
    for path in read:
        clean = os.path.normpath(path)
        if prefix and clean.startswith(prefix):
            inside.add(clean[len(prefix) :])
        elif prefix and os.path.isabs(clean):
            elsewhere.add(path)
        else:
            relative.add(path)
    return Seen(inside=inside, relative=relative, elsewhere=elsewhere)


def opened(candidate: str, read: Seen) -> bool:
    """True when the reviewer opened exactly `candidate`.

    Exact against the workspace-relative reads. The suffix test survives only
    for RELATIVE reads, where there is no prefix to strip: it guarantees
    nothing about which file was opened beyond its tail, which is how a
    vendored copy came to retire the row for the real file. An absolute path
    under another root gets neither test and so credits nothing.
    """
    if not candidate:
        return False
    if candidate in read.inside:
        return True
    needle = "/" + candidate.lstrip("/")
    return any(p == candidate or p.endswith(needle) for p in read.relative)


def openable(status: str, patch_file: str, repo_path: str, restored: tuple) -> bool:
    """Whether anything exists for the reviewer to open for this row.

    A row with a patch file always is -- including one under a restored
    path, because the patch is what it is told to read and the patch is
    intact. Without a patch the working tree is the only source, and a
    binary file, a deleted file and a reverted file each leave nothing there
    that a `Read` can return.
    """
    if patch_file not in NO_PATCH:
        return True
    if patch_file == BINARY:
        return False
    if status == REMOVED:
        return False
    return not review_io.under(repo_path, restored)


def covered_by(repo_path: str, patch: str, read: Seen) -> bool:
    """Whether this row's change was seen: either read answers for it.

    A TRUNCATED ROW SHOULD NEED BOTH -- its patch is only PART of the
    change and the remainder is only in the working tree, so crediting it
    on the patch alone lets `coverage_enforcement: fail` pass a merge over
    a change the reviewer saw one hunk of. That is the correct end state
    and it is deliberately NOT done yet.

    The blocker is that the two byte controls compose badly: a patch the
    per-file cap cut and the TOTAL budget then dropped leaves a row with no
    patch at all, so a both-reads conjunction is unsatisfiable by any
    transcript and the pull request becomes unmergeable with nothing its
    author can do. Fixing that needs budget-dropped indexes filtered out of
    the cap's set before the manifest is written, plus a `bool(patch)`
    guard here. It should also follow data on how often truncation fires,
    not precede it -- `truncated=N` on the marker is what will say.
    """
    return opened(repo_path, read) or opened(patch, read)


def _reached_and_got_nothing(candidate: str, read: Seen, tried: Seen) -> bool:
    """A `Read` was issued for `candidate` and it did not return a file.

    ATTEMPTED MINUS SUCCEEDED, not attempted. `Reads.attempted` holds every
    path a call was issued for, successes included, so testing it alone
    marked a row `+TRIED` when the reviewer had read one of its two halves
    perfectly well -- which is exactly the opposite of what the code says.
    The difference is visible whenever a row has TWO candidate paths and
    only one of them was reached -- a row with a patch the reviewer opened
    and a working-tree file it did not, or the reverse.
    """
    if not candidate:
        return False
    return opened(candidate, tried) and not opened(candidate, read)


def missed_reason(repo_path: str, patch: str, read: Seen, tried: Seen) -> str:
    """Why this openable row was not opened: a CODE, like `exempt_reason`.

    TWO INDEPENDENT FACTS, and a reader of the pull request needs both.

    The first is what the reviewer was GIVEN. `PATCH` means a whole patch
    file was written for this row and sat on disk; `WORKTREE` means none
    was, because the total byte budget dropped it or `git diff` rendered
    none, so the instruction was to open the file in the working tree.
    A patch the per-file cap cut counts as `PATCH` here: it is a patch,
    and nothing in this program distinguishes a cut one. See `covered_by`
    for why that is deliberate for now and what it costs.

    A supplied-and-unopened row is the reviewer declining; a row with no
    patch is a harder ask it also declined. Different owners, different
    fixes, and `read=29/30` alone distinguishes neither.

    The second is whether it TRIED. `+TRIED` means a `Read` was ISSUED for
    one of this row's paths and THAT path did not return a file -- it came
    back empty, it was flagged an error, OR NO RESULT WAS RECORDED FOR IT
    AT ALL, which is what a
    killed run and a changed transcript envelope both look like. All three
    are "the reviewer reached for this and did not get it", which is a
    different thing from never reaching, and `Reads.attempted` is built from
    the calls rather than the results precisely so it covers the third.
    Without the code every uncovered row looks identical on the comment, and
    four reviews of one pull request that opened 7, 7, 14 and 29 of nearly
    the same file set cannot be told apart from the only artefact that
    outlives the run.
    """
    supply = "PATCH" if patch else "WORKTREE"
    if _reached_and_got_nothing(repo_path, read, tried) or _reached_and_got_nothing(
        patch, read, tried
    ):
        return f"{supply}+TRIED"
    return supply


def exempt_reason(status: str, patch_file: str, repo_path: str, restored: tuple) -> str:
    """Why nothing could be opened for this row: a CODE, not a verdict.

    The distinction is the fourth requirement on this reviewer. "I could
    not see this" is a fact about the run, so it gets a reason code and
    appears in the coverage report; it is not a defect in the change and
    there is deliberately no severity it can be emitted under. The model
    has no vocabulary for it, and review_output.py reroutes any finding
    that reaches for one.
    """
    if patch_file == BINARY:
        return "BINARY"
    if status == REMOVED:
        return "DELETED"
    if review_io.under(repo_path, restored):
        return "RESTORED"
    return "NOPATCH"


def measure(rows: list, read: Seen, tried: Seen, restored: tuple = ()) -> tuple:
    """(covered, uncovered, exempt) repo paths, given the manifest and reads.

    `uncovered` and `exempt` entries both carry a reason code beside the
    path, in the same `path [CODE]` shape, so the two disclosures read alike
    wherever they land.

    `tried` is the same workspace split over the paths a `Read` was ISSUED
    for, a superset of `read`. It decides only the `+TRIED` half of an
    uncovered row's code and can never move a row between the three lists:
    coverage is still credited on RESULTS, never on calls, which is the
    property that stops a model satisfying the counter by issuing reads.
    """
    covered, uncovered, exempt = [], [], []
    for status, repo_path, patch_file in rows:
        if not openable(status, patch_file, repo_path, restored):
            reason = exempt_reason(status, patch_file, repo_path, restored)
            exempt.append(f"{repo_path} [{reason}]")
            continue
        patch = "" if patch_file in NO_PATCH else patch_file
        if covered_by(repo_path, patch, read):
            covered.append(repo_path)
        else:
            uncovered.append(
                f"{repo_path} [{missed_reason(repo_path, patch, read, tried)}]"
            )
    return covered, uncovered, exempt


class Tally(NamedTuple):
    """What this run established about the manifest's rows.

    One object because `report`, `write_counts` and `write_missed` all need
    the same four facts and a positional mix-up between three lists would be
    silent.

    `degraded` is the REASON this run could observe nothing about the
    reviewer's reads, empty when it could. A reason rather than a flag
    because the two causes are diagnosed in different places and the report
    has to say which.

    `unmeasured` is that same reason, EXCEPT where there was nothing for the
    instrument to measure. A manifest whose every row is exempt has no row
    whose state depends on the transcript -- the exemptions come from the
    manifest -- so its counts are real numbers however broken the stream
    was, and the token would turn a correct `0` into the non-pass the
    workflow's gate reads. The warning still goes out under `degraded`.
    """

    covered: list
    uncovered: list
    exempt: list
    unmeasured: str
    degraded: str


def unmeasured_reason(reads: Reads, seen: Seen) -> str:
    """Why no row's state is known, or "" when it is.

    NO_ENVELOPE is tested FIRST and is the stronger finding: a transcript
    that parsed and held no tool block of any name tells us nothing about
    reads, so the matchability of the read set -- which is empty -- is not a
    question that can be asked yet.

    NO_MATCH is the original case: reads happened, and not one of them
    stripped the workspace prefix or was relative. Every row then reads as
    unopened, but its state is unknown rather than zero, and on 170
    repositories at a floating tag the two must not look alike.

    The caller turns either into a token in place of the counts, and
    withholds the per-row misses, because naming every file on the pull
    request as unopened would assert the thing just disclaimed.
    """
    if reads.events and not reads.tool_events:
        return NO_ENVELOPE
    if reads.paths and not seen.inside and not seen.relative:
        return NO_MATCH
    return ""


def tally(rows: list, seen: Seen, tried: Seen, restored: tuple, reads: Reads) -> Tally:
    """Measure the manifest against the run, and say whether it is measurable.

    THE TOKEN IS WITHHELD WHERE NOTHING WAS MEASURED IN THE FIRST PLACE. A
    degraded instrument can only hide the state of a row that something
    could have opened, and when the manifest has none -- a binary-only pull
    request, every row exempt -- `0 of 0 openable` is true whatever the
    transcript was. Reporting the token there turns a green check red and
    sends its reader to the CLI pin over a change that never had a file to
    read. The diagnosis is still printed; only the counts stay numbers.
    """
    covered, uncovered, exempt = measure(rows, seen, tried, restored)
    degraded = unmeasured_reason(reads, seen)
    return Tally(
        covered=covered,
        uncovered=uncovered,
        exempt=exempt,
        unmeasured=degraded if covered or uncovered else "",
        degraded=degraded,
    )


def parse_args(argv: list) -> tuple:
    """(positional args, {flag: value}), or (None, None) on misuse."""
    options: dict = {name: None for name in FLAGS}
    args = []
    index = 0
    while index < len(argv):
        if argv[index] in FLAGS:
            if index + 1 >= len(argv):
                return None, None
            options[argv[index]] = argv[index + 1]
            index += 2
            continue
        args.append(argv[index])
        index += 1
    if len(args) != 2:
        return None, None
    return args, options


def write_counts(path: str, tallies: Tally) -> None:
    """The four counts the workflow reads, and nothing else.

    COUNTS ONLY. A path here is an environment-injection vector and these
    paths are author-chosen; the list goes to --missed-file.

    A non-empty `unmeasured` writes the token in place of all four, whichever
    of the two causes it names. A count would be a measurement, and in that
    state there was not one.
    """
    covered, uncovered, exempt = tallies.covered, tallies.uncovered, tallies.exempt
    if tallies.unmeasured:
        values: tuple = (UNMEASURED,) * 4
    else:
        values = (
            len(covered) + len(uncovered),
            len(covered),
            len(uncovered),
            len(exempt),
        )
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in zip(COUNT_KEYS, values):
            handle.write(f"{key}={value}\n")


def write_missed(path: str, uncovered: list) -> None:
    """The unopened rows, one per line, re-escaped on the way out.

    Each entry is `path [CODE]` rather than a bare path -- see
    `missed_reason` -- so the comment can say what the reviewer was given
    and whether it tried, not only that it did not open the file.
    """
    missed = [review_io.tsv_field(p) for p in uncovered[:MISSED_LIST_CAP]]
    if len(uncovered) > MISSED_LIST_CAP:
        missed.append(f"(+{len(uncovered) - MISSED_LIST_CAP} more)")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        for entry in missed:
            handle.write(f"{entry}\n")


def unmeasured_warning(
    reason: str, reads: Reads, workspace: str, withheld: bool = True
) -> str:
    """The annotation for a run that could observe nothing about the reads.

    Two causes, two places to go looking, so they are never printed alike:
    one sends the reader to `--workspace` and the transcript's path spelling,
    the other to what the pinned CLI now emits. A single message would have
    them check the wrong one half the time.

    `withheld` says whether the counts became the token. They do not when no
    row was openable, and the annotation must not claim they did -- whoever
    reads it would go looking for a coverage figure that is right there.
    """
    effect = (
        f"Coverage is reported as `{UNMEASURED}` rather than zero"
        if withheld
        else "No manifest row was openable, so the counts stand"
    )
    if reason == NO_ENVELOPE:
        return (
            "::warning::no tool_use or tool_result block appears in this"
            f" transcript's {reads.events} parsed event(s), so nothing can be"
            " observed about what the reviewer opened: the CLI's stream-json"
            f" envelope is not the one this program reads. {effect}; check"
            " the installed CLI against the pinned claude_cli_version"
        )
    return (
        f"::warning::no read path lies under {workspace} and none is"
        f" relative, so nothing could be matched. {effect}. The workspace"
        " prefix is wrong or the transcript records paths another way"
    )


def report(reads: Reads, seen: Seen, workspace: str, tallies: Tally) -> None:
    """The coverage report, on stdout, for the job log.

    `tallies.unmeasured` names why nothing could be measured, in which case
    the per-row misses are withheld, because naming every file on the pull
    request as unopened would assert the very thing the token disclaims.

    `tallies.degraded` is the same diagnosis without that consequence: the
    instrument could observe nothing AND no row needed it to, so the
    warning is printed beside counts that stand on their own.
    """
    covered, uncovered, exempt = tallies.covered, tallies.uncovered, tallies.exempt
    unmeasured = tallies.unmeasured
    print(
        f"Read calls: {reads.issued} issued, {reads.succeeded} returned a"
        f" file, {reads.failed} returned nothing or errored,"
        f" {reads.unmatched} with no result recorded."
    )
    print(f"Distinct paths attempted: {len(reads.attempted)}")
    if reads.unmatched:
        print(
            f"::warning::{reads.unmatched} Read call(s) have no recorded"
            " result, so they count as unopened; if this is not a killed run,"
            " the transcript envelope has changed shape"
        )
    print(f"Distinct paths opened: {len(reads.paths)}")
    if workspace:
        print(f"Matching: exact, {len(seen.inside)} path(s) under {workspace}.")
        if seen.elsewhere:
            print(
                f"Credited to nothing: {len(seen.elsewhere)} absolute path(s)"
                " under another root."
            )
    else:
        print("Matching: by suffix -- no --workspace given, so nothing is exact.")
    if tallies.degraded:
        print(
            unmeasured_warning(
                tallies.degraded, reads, workspace, bool(tallies.unmeasured)
            )
        )
    if unmeasured:
        print(f"Coverage: {UNMEASURED} -- no row's state is known.")
    else:
        if tallies.degraded:
            print(
                "No openable row, so nothing depended on the transcript:"
                " the counts below are measured despite the warning above."
            )
        print(
            f"Coverage: {len(covered)}/{len(covered) + len(uncovered)} openable row(s)."
        )
    print(
        f"Exempt: {len(exempt)} row(s) with nothing to open"
        " (deleted, binary, or reverted to base before the review)."
    )
    if not unmeasured:
        # THE PER-ROW LINES ARE THE INSTRUMENT, and the job log is where they
        # survive. The stream-json transcript they are derived from lives in
        # $RUNNER_TEMP and is deleted with the runner, so before these codes
        # existed the one artefact that could separate "never opened it" from
        # "opened it and got nothing" did not outlive the job -- and the
        # question could not be asked again afterwards at any price. The
        # legend is printed beside them rather than left to this file,
        # because whoever reads the log is diagnosing, not browsing source.
        if uncovered:
            print(
                "Not opened, by what the reviewer was given and whether it"
                " tried: PATCH = a patch file was written for the row;"
                " WORKTREE = no patch, so the working tree was the"
                " instruction; +TRIED = a Read was issued for it and did not"
                " return a file."
            )
        for path in uncovered:
            print(f"  ? {path}")
    for path in exempt:
        print(f"  = {path}")


def main(argv: list) -> int:
    """Measure coverage and report it. Exits 0 whatever the coverage is."""
    args, options = parse_args(argv)
    if args is None:
        print(USAGE, file=sys.stderr)
        return 2
    env_file = options["--github-env"]
    missed_file = options["--missed-file"]

    manifest_path, transcript_path = args
    rows = review_io.read_manifest(manifest_path)

    # A missing transcript is zero reads, not an error: the review may have
    # produced output without the CLI writing a parsable stream, and the
    # honest reading of that is "nothing observed", which the workflow then
    # treats as the failure it is.
    if os.path.exists(transcript_path):
        reads = read_paths(transcript_path)
    else:
        reads = Reads(
            paths=set(),
            attempted=set(),
            issued=0,
            succeeded=0,
            failed=0,
            unmatched=0,
            events=0,
            tool_events=0,
        )

    workspace = options["--workspace"] or ""
    seen = workspace_split(reads.paths, workspace)
    # Space-separated, and split on whitespace rather than parsed: the
    # workflow excludes any path containing whitespace from this value before
    # writing it, so splitting here is safe. It did once carry only a fixed
    # set of reviewer-configuration paths; it now also carries nested ignore
    # files the pull request touched, which is why the exclusion matters.
    restored = tuple((options["--restored"] or "").split())
    # The ATTEMPTED paths go through the same split as the successful ones,
    # so a `+TRIED` code is decided by the same matching rules that decide
    # coverage and the two can never disagree about which row a path is.
    tried = workspace_split(reads.attempted, workspace)
    tallies = tally(rows, seen, tried, restored, reads)

    report(reads, seen, workspace, tallies)

    if env_file:
        write_counts(env_file, tallies)

    if missed_file and not tallies.unmeasured:
        write_missed(missed_file, tallies.uncovered)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
