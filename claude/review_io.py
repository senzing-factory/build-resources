#!/usr/bin/env python3
"""The file conventions the reviewer's helper programs share.

Five small things with more than one caller: the manifest's quoting
rules and its reader, the tolerant JSON-stream reader every `gh api`
response goes through, the byte-budget parser, and the segment-wise
test for a path under a restored root. Each lives here once because a
second copy of any of them would be free to drift.

THE MANIFEST'S QUOTING.

`pr-files/manifest.tsv` is written by filter_diff.py and read by
review_coverage.py and review_output.py. Three programs, one format, and
the format has a quoting rule that is easy to get subtly wrong -- so it
lives here once rather than three times.

WHY THE QUOTING EXISTS. Git permits a newline, a tab and a backslash in a
path. A raw newline in a TSV row turns one row into two, and the second one
is attacker-chosen: it injects a second "Excluded N file(s)." line into the
log the workflow parses with `sed`, after which `[ "$x" -gt 0 ]` fails with
"integer expression expected" inside an `if` that does not trip `bash -e`,
and the PR comment silently loses its whole "files were dropped"
disclosure. The same path written into `$GITHUB_ENV` appends an arbitrary
variable to the job environment.

So every path reaches a file through `tsv_field`, and everything that
compares a manifest path against a real one puts it back through
`unescape`. THOSE TWO MUST STAY EXACT INVERSES, which is the whole argument
for one copy: a `tsv_field` that gained a case its `unescape` did not would
make the affected paths unmatchable, and the symptom -- a file reported
unreviewed forever, no matter how carefully it was read -- looks nothing
like a quoting bug.
"""

import json
import os
import sys

# Escaped form -> the character it stands for. `unescape` is driven by this
# table so the two functions cannot drift in what they cover.
UNESCAPE = {"\\": "\\", "t": "\t", "r": "\r", "n": "\n"}


def tsv_field(path: str) -> str:
    """C-quote the characters that would break a TSV row or a log line.

    The backslash goes FIRST. Escaping it after the others would re-escape
    the backslashes they just introduced, turning a tab into a literal
    backslash-t that `unescape` then reads back as a backslash and a `t`.
    """
    return (
        path.replace("\\", "\\\\")
        .replace("\t", "\\t")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )


def unescape(field: str) -> str:
    """Undo `tsv_field`, left to right.

    Left to right matters: a literal backslash is written as two, so a
    repeated-replace pass would turn an escaped backslash followed by `t`
    into a tab.
    """
    out = []
    index = 0
    while index < len(field):
        char = field[index]
        if char == "\\" and index + 1 < len(field) and field[index + 1] in UNESCAPE:
            out.append(UNESCAPE[field[index + 1]])
            index += 2
            continue
        out.append(char)
        index += 1
    return "".join(out)


def under(path: str, roots: tuple) -> bool:
    """True when `path` IS one of `roots` or lies inside one of them.

    Segment-wise, so `.husky-local/x` is not under `.husky`. Shared because
    review_coverage.py and review_output.py both decide something about the
    paths the workflow reverted to base content, and two copies of this test
    could disagree about which rows those are.
    """
    return any(path == root or path.startswith(root + "/") for root in roots)


def read_manifest(path: str) -> list:
    """The manifest as (status, repo path, patch token) triples.

    Columns are status, changes, path, patch_file. A row with fewer than
    four fields is a CORRUPT MANIFEST and raises: the alternative is
    skipping it, and a skipped row is a file that silently leaves the
    denominator -- which is the exact failure the manifest exists to
    prevent. Extra columns are tolerated so a later field can be added
    without breaking a reader that does not want it.
    """
    rows = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) < 4:
                raise ValueError(f"manifest row has {len(fields)} fields: {line!r}")
            rows.append((fields[0], unescape(fields[2]), fields[3]))
    return rows


def json_values(raw: str):
    """Yield every top-level JSON value in a concatenated stream.

    `gh api --paginate` emits one spliced array, several arrays, or one
    object per line depending on version and flags. Decoding values until
    the input runs out accepts all of those, so a step cannot break on a
    gh upgrade that changes how pages are joined.
    """
    decoder = json.JSONDecoder()
    index, end = 0, len(raw)
    while index < end:
        while index < end and raw[index].isspace():
            index += 1
        if index >= end:
            return
        value, index = decoder.raw_decode(raw, index)
        yield value


def json_records(path: str) -> list:
    """Every dict in a JSON file holding a list, or several lists."""
    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()
    out: list = []
    for value in json_values(raw):
        if isinstance(value, list):
            out.extend(v for v in value if isinstance(v, dict))
        elif isinstance(value, dict):
            out.append(value)
    return out


def json_object(path: str) -> dict:
    """The first JSON object in a file, or an empty one."""
    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()
    for value in json_values(raw):
        if isinstance(value, dict):
            return value
    return {}


def checked_budget(name: str) -> int:
    """A non-negative integer from the environment, or -1 having said why.

    -1 rather than an exception, and a message on stderr rather than
    silence: a malformed budget must not read as "no backstop", which is
    what 0 means, and must not read as a crash either, which the workflow
    would turn into "the review could not run".
    """
    try:
        value = int(os.environ.get(name, "0"))
    except ValueError:
        value = -1
    if value < 0:
        print(
            f"{name} must be a non-negative integer, got {os.environ.get(name)!r}",
            file=sys.stderr,
        )
        return -1
    return value


def json_lines(path: str):
    """Yield one value per line of a newline-delimited JSON file.

    Yields None for a line that does not parse, rather than skipping it, so
    a caller can report the gap -- `--events` prints it as
    `<unparsable line>` and the coverage check treats it as nothing
    observed.

    WHY A BAD LINE IS NOT FATAL. This reads the Claude Code transcript, and
    a killed or timed-out run leaves a truncated final line. Raising there
    would lose the whole review, including the reads recorded before the
    run died; under-reporting coverage fails toward "not reviewed", which
    is the safe direction.
    """
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except ValueError:
                yield None
