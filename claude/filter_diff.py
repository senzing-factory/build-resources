#!/usr/bin/env python3
# The untrusted-context renderer was split out to pr_discussion.py and the
# shared file conventions to review_io.py, which is as far as this file
# divides along a seam that means anything: what is left is one job --
# turn a commit range into the review set -- told at this repository's
# usual density of rationale, where most of the length is the record of
# which defect each line is there to stop. Splitting it again would put
# half of one argument in each of two files.
# pylint: disable=too-many-lines
"""Assemble the reviewable part of a pull request, dropping excluded paths.

Two modes, one exclude-glob implementation:

    filter_diff.py --manifest <out_dir> <base_rev> <head_rev> [<files_json>]
        Write `<out_dir>/manifest.tsv` plus one `<out_dir>/NNNN.patch` per
        surviving file, describing `base_rev..head_rev` -- the pull
        request's merge base and its head. This is the mode the workflow
        uses: the reviewer reads the manifest and pages in the patches it
        needs, so the prompt stays a constant size whatever the PR's size.

        EVERY FACT COMES FROM GIT PLUMBING. `git diff --raw -z` supplies the
        file list, each path's status and its pre- and post-image blob
        names; `git diff --numstat -z` supplies the line counts; one
        `git diff` supplies the patch bytes. `<files_json>` -- the JSON of
        `gh api repos/{o}/{r}/pulls/{n}/files --paginate` -- is used for
        exactly one thing: as a SECOND, INDEPENDENT WITNESS to the file
        list. A disagreement exits 3 rather than being reconciled.

        That inversion is the point: the file list is the DENOMINATOR a
        coverage check divides by, and the API's is not fit to be one. See
        `write_manifest` for why, and for what it cost.

        BINARY-NESS IS READ FROM THE BLOB, never from `.gitattributes`.
        `git diff` resolves it through the attributes of the tree under
        review, so one added line marking a source file `-diff` makes git
        report it as "Binary files ... differ" -- and a reviewer told a file
        is binary is a reviewer told not to open it. `sniff_binary` asks
        `git cat-file` for the object instead and applies git's own test, a
        NUL byte in the first 8000. Where the two verdicts disagree the path
        is named as an attribute conflict and still handed to the reviewer to
        open: failing toward "go and look" is this program's direction.

    filter_diff.py <input_diff> <output_diff>
        Filter a unified diff, dropping whole file sections whose path
        matches an exclude glob. Kept for a standalone local `git diff`.

The pull request's own description and comment thread are rendered by
`pr_discussion.py`, which used to be a third mode here. It was split out
because nothing in it touches a patch and everything in it touches
attacker-controlled text, and a trust boundary is worth reading on its own.

Exclude globs are read from the EXCLUDE_GLOBS env var (newline- or
comma-separated). Glob matching uses fnmatch, so `*` also spans `/`
(e.g. `*vendor/*` matches `a/b/vendor/c`). In diff mode, matching is done
against the post-image path (the `b/...` side of the `diff --git` header).

MAX_REVIEW_BYTES caps the total patch bytes written in manifest mode. Over
budget, whole patches are dropped largest-first and the file keeps its
manifest row with no patch file, so the reviewer still sees the path and
the change count and can open the file in the working tree. Naming what was
not supplied is honest; splitting the PR into chunks that cannot see each
other is not.

Manifest mode prints FOUR drop reports, and the workflow turns each into its
own section of the PR comment: `Excluded` for paths an exclude glob removed,
`Omitted` for patches the byte budget dropped, `Binary` for files whose blob
content is binary, and `Unpatched` for a path `git diff` rendered no section
for. Naming all four on the pull request is the disclosure that was missing
on 2026-10-21. The distinction that matters to a reader is that an
`Unpatched` row can still be opened in the working tree, unless it was
deleted, while a `Binary` row cannot be opened by anything.

The diff is read and written as BYTES, so a file in any encoding (or with
invalid UTF-8) reaches the model unaltered. Only the header lines needed for
glob matching are decoded, lossily, and that decoded text never reaches the
output.
"""

import fnmatch
import os
import re
import subprocess
import sys
from typing import NamedTuple

import review_io
from review_io import tsv_field

# How many bytes of a blob decide whether it is binary. git's own heuristic
# in `buffer_is_binary()` is "a NUL byte in the first 8000", and matching it
# means this program and `git diff` agree about the same file.
BINARY_SNIFF_BYTES = 8000

# How much of a blob is read at a time while sniffing. The whole blob has to
# come off the pipe -- `cat-file --batch` has no way to say "stop" mid-record
# without desynchronising the stream -- but only the first
# BINARY_SNIFF_BYTES are retained, so memory stays bounded whatever the file.
BLOB_CHUNK_BYTES = 65536

# `git diff` flags that keep a pull request from choosing how its own change
# is rendered. --no-ext-diff ignores a configured external differ,
# --no-textconv ignores a `diff=<driver>` textconv filter, and
# core.quotePath=false keeps non-ASCII paths as raw UTF-8 bytes rather than
# C-quoted escapes, so the -z records carry the real path.
GIT_DIFF_FLAGS = ("--no-ext-diff", "--no-textconv", "--find-renames")
GIT_CONFIG_FLAGS = ("-c", "core.quotePath=false")


def is_null_sha(sha: str) -> bool:
    """True for git's all-zero object name, at any width.

    An all-zero name is git's "this side does not exist": the pre-image of an
    addition, the post-image of a deletion. It is matched BY SHAPE rather than
    against a fixed-width constant because `git diff --raw` ABBREVIATES object
    names -- a deletion's post-image arrives as `0000000`, and the forty-zero
    constant this replaced never matched it. Every deleted binary file was
    therefore sniffed from its own absent post-image, came back "not binary",
    and was named as an attribute conflict: the alarm this program raises for
    a pull request suppressing its own patch, fired by `git rm logo.png`.

    `git_raw_records` now passes `--no-abbrev`, for a different reason, and
    this test still earns its place: the width is not the only thing that
    varies, because in a sha256 repository the null name is sixty-four zeros
    and a forty-zero constant is wrong there too. A shape test is independent
    of both the abbreviation length and the object format.
    """
    return bool(sha) and set(sha) == {"0"}


def _text(raw: bytes) -> str:
    """Decode a header line for matching only; never written back out."""
    return raw.decode("utf-8", "replace")


def _unquote(tok: str) -> str:
    """Undo git's C-style quoting of a path, if present."""
    if len(tok) >= 2 and tok.startswith('"') and tok.endswith('"'):
        try:
            return (
                tok[1:-1]
                .encode("latin-1", "backslashreplace")
                .decode("unicode_escape")
                .encode("latin-1", "backslashreplace")
                .decode("utf-8", "replace")
            )
        except (UnicodeDecodeError, UnicodeEncodeError):
            return tok[1:-1]
    return tok


def _strip_prefix(path: str) -> str:
    return path[2:] if path[:2] in ("a/", "b/") else path


def _header_path(raw: bytes) -> str:
    """The path token from a `--- ` or `+++ ` header line.

    The trailing TAB matters: git appends one after the filename whenever the
    path contains a space, so without this strip the key carries a tab, never
    matches a record's filename, and that file falls back to the API patch
    this program exists to stop relying on. A path that genuinely ENDS in a
    tab is C-quoted by git and so ends in `"`, which is why stripping is safe;
    measured on git 2.x for a space, a space plus non-ASCII, and a literal
    tab in the name.
    """
    return _text(raw)[4:].rstrip("\r\n").rstrip("\t")


def section_path(section: list) -> str:
    """The path a diff section is about, or "" if it cannot be determined.

    `section` is a list of raw lines (bytes); only the header lines are decoded.

    Preference order, and why:

    1. The "+++ b/<path>" line. Unambiguous even when the path contains spaces
       -- see `_header_path` for the tab git appends in that case -- and for a
       rename it is already the NEW path.
    2. For a deletion ("+++ /dev/null"), the "--- a/<path>" line instead, so a
       deleted excluded file is still excluded.
    3. The "diff --git" header, which is the only option for a BINARY file --
       those carry no ---/+++ lines at all, and binary paths are most of what
       the default globs target (*.png, *.pdf, *.woff). git quotes paths with
       non-ASCII or special characters here, so handle both forms. An unquoted
       path containing " b/" stays irreducibly ambiguous in this line; git
       itself cannot disambiguate it either.
    """
    minus = ""
    for raw in section[1:]:
        if raw.startswith(b"diff --git "):
            break
        if raw.startswith(b"--- "):
            minus = _header_path(raw)
        elif raw.startswith(b"+++ "):
            plus = _header_path(raw)
            if plus != "/dev/null":
                return _strip_prefix(_unquote(plus))
            if minus and minus != "/dev/null":
                return _strip_prefix(_unquote(minus))
            return ""

    header = _text(section[0]).rstrip("\r\n")
    if not header.startswith("diff --git "):
        return ""
    rest = header[len("diff --git ") :]
    quoted = re.findall(r'"(?:[^"\\]|\\.)*"', rest)
    if len(quoted) == 2:
        return _strip_prefix(_unquote(quoted[1]))
    parts = rest.split(" b/", 1)
    return _strip_prefix("b/" + parts[1].strip()) if len(parts) == 2 else ""


def read_globs() -> list:
    """The exclude globs from EXCLUDE_GLOBS, newline- or comma-separated."""
    raw = os.environ.get("EXCLUDE_GLOBS", "").replace(",", "\n")
    return [g.strip() for g in raw.splitlines() if g.strip()]


def excluded(path: str, globs: list) -> bool:
    """True when `path` matches any exclude glob. An empty path never does."""
    return bool(path) and any(fnmatch.fnmatch(path, g) for g in globs)


def report(dropped: list) -> None:
    """The exclusion report the workflow parses into the PR comment."""
    print(f"Excluded {len(dropped)} file(s) from review.")
    for path in sorted(dropped):
        print(f"  - {tsv_field(path)}")


def report_unpatched(unpatched_paths: list) -> None:
    """The fourth drop report: no patch exists for these paths.

    A separate bullet again, and a separate count, because the cause is
    neither ours nor the budget's: nothing could render a diff for them -- a
    mode-only change on the API fallback path, or a path neither the local
    diff nor the API supplied anything for. Until this report existed the
    token appeared only as `-` in the manifest, so a file could reach the
    reviewer with no diff and nothing anywhere said so -- not the job log,
    not the run context, not the posted comment.
    """
    print(f"Unpatched {len(unpatched_paths)} file(s): no diff could be rendered.")
    for path in sorted(unpatched_paths):
        print(f"  ! {tsv_field(path)}")


def report_binary(binary_paths: list) -> None:
    """The third drop report: git reports these as binary.

    Kept apart from `Unpatched` because the reviewer's options differ. An
    unpatched text file is still in the working tree and must be opened
    there; a binary one has nothing to read either way, so naming it stops
    the "open it in the working tree" instruction sending the reviewer at a
    file `Read` will refuse.

    There is no undetectable case left to disclose. The verdict comes from
    the blob's own bytes via `git cat-file`, which exist for every path in
    the range; the API fallback that could not tell a binary file from a
    mode-only change -- both arrive with no `patch` and `changes == 0` -- is
    gone, and with it the `detectable` flag this used to carry.
    """
    print(f"Binary {len(binary_paths)} file(s): no reviewable content.")
    for path in sorted(binary_paths):
        print(f"  ~ {tsv_field(path)}")


def report_omitted(omitted_paths: list, budget: int) -> None:
    """The over-budget report. A different bullet from report()'s exclusions.

    The workflow parses the two separately and shows them under different
    headings: a path dropped by a glob was never going to be reviewed, while
    one dropped here changed and simply did not fit.
    """
    print(f"Omitted {len(omitted_paths)} file(s) to fit MAX_REVIEW_BYTES={budget}.")
    for path in sorted(omitted_paths):
        print(f"  * {tsv_field(path)}")


def split_sections(data: bytes) -> list:
    """A unified diff split into per-file sections at each `diff --git`.

    Bytes in, bytes out: the diff may hold any encoding, so only the header
    lines needed for matching are decoded, and lossily.
    """
    sections: list[list[bytes]] = []
    current: list[bytes] = []
    for line in data.splitlines(keepends=True):
        if line.startswith(b"diff --git "):
            if current:
                sections.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        sections.append(current)
    return sections


def local_patches_from_bytes(data: bytes, globs: list) -> tuple:
    """(path -> patch bytes, set of paths git rendered as binary) from a diff.

    The whole diff is split into sections BEFORE any glob is applied --
    split_sections() returns a list -- so the globs bound what is retained as
    patch bytes, not peak memory. `git diff` has no size cap, which is the
    point of using it, so a change touching a large generated tree produces a
    large diff and that diff is held whole for the length of this call.

    EVERY section git rendered is kept whole except a binary one, and that
    includes a section with no `@@ ` hunk. A mode change and a pure rename
    are complete, self-describing patches of about ninety bytes, and those
    lines ARE the whole change. Discarding them reported a 644 -> 755 file
    as "no diff could be rendered" and sent the reviewer to open it in the
    working tree, where the content is byte-identical and the executable bit
    cannot be seen at all; the same shape lost a pure rename's old path.

    A binary file is the one exception and maps to empty bytes plus an entry
    in the returned set. `git diff` without `--binary` renders it as a single
    `Binary files ... differ` line, which is exactly the signal wanted and
    the reason the workflow does not pass `--binary`. Base85 blobs would be
    worthless to a reviewer and would spend the byte budget.

    That signal is only trustworthy because the workflow neutralizes the
    `-diff` attribute first: git emits the same line for any path marked
    `-diff` whatever the content, and resolves attributes from the merge
    checkout, which is the pull request's OWN `.gitattributes`. See the
    `* !diff` line in the workflow's "Collect reviewable files" step.

    The binary set falls out of the same pass and the manifest path discards
    it. `git_records` compares git's verdict against the blob's own content
    using `--numstat`'s `-` instead, and that is the better witness of the
    two: it is a field, keyed by a NUL-delimited path, where this set is the
    English string "Binary files " matched against patch text and keyed by a
    path parsed back out of a `diff --git` header.
    """
    patches: dict = {}
    binary = set()
    for section in split_sections(data):
        path = section_path(section)
        if not path or excluded(path, globs):
            continue
        if any(
            line.startswith(b"Binary files ") or line.startswith(b"GIT binary patch")
            for line in section
        ):
            patches[path] = b""
            binary.add(path)
        else:
            patches[path] = b"".join(section)
    return patches, binary


def filter_diff(in_path: str, out_path: str, globs: list) -> int:
    """Copy a unified diff, dropping whole file sections the globs match.

    Bytes in, bytes out: the diff may hold any encoding, so only the
    header lines needed for glob matching are decoded, and lossily.
    """
    with open(in_path, "rb") as fh:
        sections = split_sections(fh.read())

    kept, dropped = [], []
    for section in sections:
        path = section_path(section)
        if excluded(path, globs):
            dropped.append(path)
            continue
        kept.extend(section)

    with open(out_path, "wb") as fh:
        fh.writelines(kept)

    report(dropped)
    print(f"Files: {len(sections) - len(dropped)}")
    return 0


def load_records(path: str) -> list:
    """The file records from a `pulls/{n}/files` JSON response.

    Tolerates the several-concatenated-lists shape `--paginate` emits.
    """
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()
    records = []
    for value in review_io.json_values(raw):
        if isinstance(value, list):
            records.extend(value)
        elif isinstance(value, dict):
            records.append(value)
    return [r for r in records if isinstance(r, dict) and r.get("filename")]


def rename_patch(record: dict) -> bytes:
    """A self-describing patch for a rename git rendered with no body.

    `git diff` emits a rename whose content did not change as a header, a
    `similarity index 100%` line and the two paths, with no `@@` hunk. Those
    lines ARE the whole change, so they are kept rather than discarded -- an
    earlier version dropped them, reported "no diff could be rendered", and
    sent the reviewer to open a working-tree file whose bytes are identical
    and whose only change is its name. This renders the same shape for the
    case where the range produced no section at all.
    """
    old = record.get("previous_filename") or record["filename"]
    return (
        f"diff --git a/{old} b/{record['filename']}\n"
        "similarity index 100%\n"
        f"rename from {old}\n"
        f"rename to {record['filename']}\n"
    ).encode("utf-8")


def patch_for(record: dict, local: dict) -> bytes:
    """Patch bytes for one record, from the local diff.

    A path whose section git rendered as "Binary files ... differ" maps to
    empty bytes in `local`, and empty is what it stays: there is no second
    source to fall back to any more, and that is the point. The manifest's
    `binary` token now comes from the blob's own content, so a file git
    declined to diff BECAUSE OF AN ATTRIBUTE lands as `-` -- no patch, and
    the reviewer is told to open it in the working tree -- rather than as
    `binary`, which would tell the reviewer there is nothing to open.
    Failing toward "go and look" is the whole direction of this change.
    """
    name = record["filename"]
    if local.get(name):
        return local[name]
    if name not in local and record["status"] == "renamed" and not record["changes"]:
        return rename_patch(record)
    return b""


class GitError(RuntimeError):
    """A git command this program depends on failed or returned nonsense."""


def _git(args: list, cwd: str = ".") -> bytes:
    """Run git and return stdout as bytes, raising GitError on failure.

    stdout is BYTES throughout. A path is a byte string to git, and decoding
    it here would corrupt any path that is not valid UTF-8 -- which is
    exactly the path a change would use to slip out of the manifest.
    """
    proc = subprocess.run(
        ["git", *args],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        raise GitError(f"git {' '.join(args[:4])} failed: {detail}")
    return proc.stdout


def _raw_status(token: str) -> tuple:
    """(manifest status, how many paths this record carries) for a raw token.

    The token is a letter and, for a rename or copy, a similarity score:
    `M`, `A`, `D`, `T`, `R086`, `C075`. A rename and a copy carry two paths,
    everything else carries one; getting that count wrong desynchronises the
    whole NUL-separated stream, so it is derived here and nowhere else.
    """
    letter = token[:1]
    if letter in ("R", "C"):
        return "renamed", 2
    return {"A": "added", "D": "removed", "T": "modified"}.get(letter, "modified"), 1


def git_raw_records(base: str, head: str, cwd: str = ".") -> list:
    """One record per changed path from `git diff --raw -z`.

    `--raw` is the only diff format that states, per path, the pre- and
    post-image MODES and BLOB NAMES. Those blob names are what makes
    binary-ness computable from content: given the object id, the content
    can be sniffed directly, with no attribute and no diff driver in
    between.

    `-z` is load-bearing. Without it git C-quotes any path containing a
    newline, a tab or a non-ASCII byte, and the three quoting forms differ
    between the raw, numstat and patch outputs -- so the path sets stop
    matching each other precisely when a change contains the kind of path
    somebody chose deliberately. With `-z` every path is a raw NUL-
    terminated byte string and there is nothing to unquote.

    `--no-abbrev` so those names are object ids rather than prefixes.
    `sniff_binary` resolves each one in a SEPARATE `cat-file` process, and a
    prefix that `git diff` found unique can stop being unique between the two
    -- `cat-file` then answers `ambiguous`, which that function reads as "no
    verdict", which lands as a false attribute conflict and a `-` row the
    reviewer cannot open. Only the field WIDTHS change; the record is still
    five space-separated fields and then the NUL-separated paths.
    """
    out = _git(
        [
            *GIT_CONFIG_FLAGS,
            "diff",
            "--raw",
            "-z",
            "--no-abbrev",
            *GIT_DIFF_FLAGS,
            base,
            head,
        ],
        cwd,
    )
    tokens = out.split(b"\x00")
    records: list = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if not token.startswith(b":"):
            index += 1
            continue
        fields = token[1:].decode("utf-8", "replace").split(" ")
        if len(fields) < 5:
            raise GitError(f"unparsable --raw record: {token!r}")
        status, path_count = _raw_status(fields[4])
        paths = tokens[index + 1 : index + 1 + path_count]
        if len(paths) < path_count or any(not p for p in paths):
            raise GitError(f"--raw record is missing a path: {token!r}")
        old_path = paths[0].decode("utf-8", "surrogateescape")
        new_path = paths[-1].decode("utf-8", "surrogateescape")
        records.append(
            {
                "filename": new_path,
                "previous_filename": old_path if path_count == 2 else None,
                "status": status,
                "old_mode": fields[0],
                "new_mode": fields[1],
                "old_sha": fields[2],
                "new_sha": fields[3],
            }
        )
        index += 1 + path_count
    return records


def git_numstat(base: str, head: str, cwd: str = ".") -> dict:
    """{path: (additions, deletions, git_called_it_binary)} from --numstat -z.

    git reports `-` for both counts on a file it will not line-count, which
    is its own binary verdict. That verdict is recorded but NOT used as the
    answer -- see `sniff_binary` -- because it is the one git resolves
    through `.gitattributes`, which the pull request under review owns. It
    is kept so the two can be compared: a file git calls binary and the
    blob's own content calls text means the attribute neutralisation in the
    workflow did not take, which is the attack rather than a quirk.
    """
    out = _git(
        [
            *GIT_CONFIG_FLAGS,
            "diff",
            "--numstat",
            "-z",
            *GIT_DIFF_FLAGS,
            base,
            head,
        ],
        cwd,
    )
    tokens = out.split(b"\x00")
    counts: dict = {}
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if b"\t" not in token:
            index += 1
            continue
        adds, dels, rest = token.split(b"\t", 2)
        if rest:
            path = rest.decode("utf-8", "surrogateescape")
            index += 1
        else:
            # A rename: the path field is empty and the old and new paths
            # follow as their own NUL-terminated tokens.
            if index + 2 >= len(tokens):
                raise GitError(f"truncated --numstat rename record: {token!r}")
            path = tokens[index + 2].decode("utf-8", "surrogateescape")
            index += 3
        binary = adds == b"-" or dels == b"-"
        counts[path] = (
            0 if binary else int(adds or 0),
            0 if binary else int(dels or 0),
            binary,
        )
    return counts


def _drain_object(stream, size: int, sha: str, keep: int) -> bytes:
    """Take one `cat-file --batch` body off the pipe; return its first `keep`.

    THE WHOLE BODY HAS TO COME OFF THE PIPE whatever kind of object it is.
    `--batch` offers no way to say "stop" mid-record, so a body left unread is
    read by the next `readline()` as though it were a header -- and from there
    the request and response streams never come back into step: every object
    sorted after the undrained one loses its answer or is given another
    object's. Only the first `keep` bytes are retained, so a 2 GB asset costs
    time and not memory; `keep` of 0 drains and keeps nothing.
    """
    remaining = size
    prefix = b""
    while remaining > 0:
        chunk = stream.read(min(BLOB_CHUNK_BYTES, remaining))
        if not chunk:
            raise GitError(f"cat-file truncated the object {sha}")
        remaining -= len(chunk)
        if len(prefix) < keep:
            prefix += chunk[: keep - len(prefix)]
    stream.read(1)  # the newline cat-file appends
    return prefix


def sniff_binary(shas: list, cwd: str = ".") -> dict:
    """{blob sha: True if its content is binary} read from the object itself.

    THE POINT OF THIS FUNCTION is that it consults nothing a pull request
    can write. `git diff` decides binary-ness through `.gitattributes`,
    which lives in the tree under review, so a single added line marking a
    source file `-diff` makes git report it as "Binary files ... differ" --
    and a reviewer told a file is binary is a reviewer told not to open it.
    An object id and its bytes have no such channel.

    The test is git's own: a NUL byte within the first BINARY_SNIFF_BYTES.
    Matching the heuristic rather than inventing one means the patch bytes
    and this verdict describe the same file the same way.

    One `cat-file --batch` process for the whole set, driven one object at a
    time so the request and response stay in step. Staying in step is the
    fragile part and `_drain_object` is where it is kept: a record whose body
    is not read is read as the next record's header. An END OF STREAM is not
    an answer and is fatal: it is indistinguishable from the two-field
    `missing` reply by field count alone, and reading it as one hands every
    later sha a default verdict it was never asked about.
    """
    wanted = sorted({s for s in shas if s and not is_null_sha(s)})
    if not wanted:
        return {}
    verdicts: dict = {}
    with subprocess.Popen(
        ["git", "cat-file", "--batch"],
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ) as proc:
        # Narrowed once rather than asserted at each use: Popen with PIPE on
        # both always sets these, but the annotation is Optional and mypy is
        # right that nothing here proves it.
        stdin, stdout = proc.stdin, proc.stdout
        if stdin is None or stdout is None:
            raise GitError("cat-file was started without the pipes it needs")
        try:
            for sha in wanted:
                try:
                    stdin.write(f"{sha}\n".encode("ascii"))
                    stdin.flush()
                except OSError as exc:
                    # A process that has already died shows up here first,
                    # as a broken pipe, rather than at the read below.
                    raise GitError(
                        f"cat-file stopped accepting requests at {sha}: {exc}"
                    ) from exc
                header = stdout.readline()
                if not header:
                    # END OF STREAM, AND IT IS NOT THE ANSWER BELOW. An
                    # exited `cat-file` returns b"", which splits into no
                    # fields, so the `len(parts) < 3` test below cannot
                    # tell it from a legitimate `<sha> missing` -- and read
                    # as `missing`, every remaining sha is left with no
                    # verdict, defaulted to "not binary" by `git_records`
                    # and reported as an attribute conflict if it really
                    # was binary. Fail the run: a verdict this function
                    # could not take from the object is not a verdict.
                    raise GitError(f"cat-file ended the stream before answering {sha}")
                parts = header.decode("utf-8", "replace").split()
                if len(parts) < 3 or not parts[2].isdigit():
                    # `<sha> missing`, or `<sha> ambiguous`: a two-field
                    # answer carrying NO BODY, so there is nothing to drain.
                    # An ordinary submodule bump lands here, because this
                    # repository does not have the target commit; so does
                    # any object this checkout is missing. Not binary, and
                    # not readable either; the row's patch token says the
                    # rest.
                    continue
                if parts[1] != "blob":
                    # A GITLINK WHOSE TARGET COMMIT THIS REPOSITORY HAS --
                    # a submodule that is a clone of this same repository,
                    # or one `git update-index` line adding a 160000 entry,
                    # from a pull request that wants this stream broken.
                    # `cat-file` answers with the commit object AND ITS
                    # BODY. Treating it like the `missing` answer, which has
                    # none, left that body on the pipe and cost every object
                    # sorted after it its verdict -- which reported a
                    # genuinely binary file as an attribute conflict and gave
                    # it a `-` row the reviewer is told to open and cannot.
                    # Same verdict as `missing` -- not binary -- once drained.
                    _drain_object(stdout, int(parts[2]), sha, 0)
                    continue
                verdicts[sha] = b"\x00" in _drain_object(
                    stdout, int(parts[2]), sha, BINARY_SNIFF_BYTES
                )
        finally:
            stdin.close()
    if proc.returncode:
        # Closing stdin ends a healthy `cat-file` with 0, so anything else
        # means the answers above came from a process that was failing --
        # and `stderr` is discarded, so nothing else would ever say so.
        raise GitError(f"cat-file exited {proc.returncode}")
    return verdicts


def _sniff_sha(record: dict) -> str:
    """The blob whose own content decides this record's binary-ness.

    A deletion has no post-image, so the pre-image blob is what decides
    whether there was ever anything readable there. Derived here and used
    twice, because the two call sites have to agree about which object was
    asked for: the second one is a dictionary lookup keyed on the first one's
    answer, and a disagreement between them is a silent "not binary".
    """
    new_sha = record["new_sha"]
    return record["old_sha"] if is_null_sha(new_sha) else new_sha


def git_records(base: str, head: str, cwd: str = ".") -> tuple:
    """(records, attribute-conflict paths) describing every changed path.

    Each record is shaped like a `pulls/{n}/files` entry, so everything
    downstream of here does not care which source it came from -- but every
    field in it was computed locally from git plumbing, and the file list is
    git's. That list IS the denominator the coverage check divides by, which
    is why it is not taken from an API response that silently caps at 3,000
    files and omits the patch for about one file in ten.

    The returned conflict list names paths where `git diff` called the file
    binary and its blob content did not. That disagreement means an
    attribute reached the diff, and the workflow reports it rather than
    quietly preferring one answer.
    """
    records = git_raw_records(base, head, cwd)
    counts = git_numstat(base, head, cwd)
    sniffed = sniff_binary([_sniff_sha(r) for r in records], cwd)
    conflicts: list = []
    for record in records:
        adds, dels, git_binary = counts.get(record["filename"], (0, 0, False))
        content_binary = sniffed.get(_sniff_sha(record), False)
        if git_binary and not content_binary:
            conflicts.append(record["filename"])
        record["additions"] = adds
        record["deletions"] = dels
        record["changes"] = adds + dels
        record["binary"] = content_binary
    return records, conflicts


def git_diff_bytes(base: str, head: str, cwd: str = ".") -> bytes:
    """The patch bytes for the whole range, as one unified diff.

    No `--binary`: a binary file then renders as the single line
    `Binary files a/x and b/x differ`, and base85 blobs would be unreadable
    to a reviewer and would spend the byte budget on nothing. The manifest's
    `binary` token comes from `sniff_binary`, not from that line.
    """
    return _git(
        [
            *GIT_CONFIG_FLAGS,
            "diff",
            "--no-color",
            *GIT_DIFF_FLAGS,
            base,
            head,
        ],
        cwd,
    )


def api_path_union(json_path: str) -> set:
    """Every path `pulls/{n}/files` names, old and new sides together.

    The union, not the new-side list, because git and GitHub run their own
    rename detection and need not agree about WHICH change a pair of paths
    represents. A move git calls `R` and GitHub calls an add plus a delete
    still names the same two paths on both sides, so comparing unions tests
    the thing that matters -- did either source see a path the other did not
    -- without failing on a classification difference that changes nothing
    about what gets reviewed.
    """
    paths = set()
    for record in load_records(json_path):
        paths.add(record["filename"])
        previous = record.get("previous_filename")
        if previous:
            paths.add(previous)
    return paths


def crosscheck(records: list, json_path: str) -> tuple:
    """(agreed, message) comparing git's path set against the API's.

    Two independent derivations of the same denominator. They are compared
    rather than merged because a difference is a fact about the tooling,
    not a set to reconcile: git reading a different range, a stale merge
    ref, or the API's own 3,000-file cap all show up here, and each of them
    invalidates the coverage figure that the rest of this program computes.

    The 3,000-file cap is the one documented, benign difference, so it is
    named rather than reported as a disagreement -- but it is still
    reported, because above that size the API cannot corroborate anything
    and the reviewer should be told the denominator has one witness.
    """
    api = api_path_union(json_path)
    mine = set()
    for record in records:
        mine.add(record["filename"])
        if record.get("previous_filename"):
            mine.add(record["previous_filename"])

    missing_here = sorted(api - mine)
    missing_there = sorted(mine - api)
    if not missing_here and not missing_there:
        return True, f"Crosscheck: ok, {len(mine)} path(s) agreed with the files API."
    if len(api) >= 3000 and not missing_here:
        return True, (
            f"Crosscheck: the files API capped at {len(api)} path(s) and git"
            f" found {len(mine)}; above the cap the API cannot corroborate the"
            " file list, so the denominator has one witness."
        )
    detail = []
    if missing_here:
        detail.append(
            "in the API and not in git: "
            + ", ".join(tsv_field(p) for p in missing_here[:10])
        )
    if missing_there:
        detail.append(
            "in git and not in the API: "
            + ", ".join(tsv_field(p) for p in missing_there[:10])
        )
    return False, "Crosscheck: MISMATCH -- " + "; ".join(detail)


def _partition(records: list, globs: list) -> tuple:
    """Split the file records into (kept, paths dropped by an exclude glob)."""
    kept, dropped = [], []
    for record in records:
        if excluded(record["filename"], globs):
            dropped.append(record["filename"])
        else:
            kept.append(record)
    return kept, dropped


def _fit_patches(kept: list, patches: list, budget: int) -> tuple:
    """Which patch indexes to drop, and the byte total of those that stay.

    Over budget, whole patches go largest-first until the rest fit. Ranked
    by patch BYTES rather than the `changes` proxy, because bytes are what
    the budget is denominated in. A budget of 0 drops nothing.
    """
    sizes = {i: len(p) for i, p in enumerate(patches) if p}
    total = sum(sizes.values())
    omitted: set = set()
    if budget > 0:
        for index in sorted(sizes, key=lambda i: (-sizes[i], kept[i]["filename"])):
            if total <= budget:
                break
            omitted.add(index)
            total -= sizes[index]
    return omitted, total


class ReviewSet(NamedTuple):
    """What `_write_review_set` wrote, and all the caller has to report.

    One named return rather than five parallel ones: the five-tuple put both
    that function and `write_manifest` over pylint's locals limit, and the
    fields are what the PR comment's disclosure sections are built from.
    """

    omitted: list
    unpatched: list
    binary: list
    additions: int
    deletions: int


def _write_patch(patch: bytes, index: int, out_dir: str) -> str:
    """Write one patch file, and return the manifest token naming it."""
    name = f"{index + 1:04d}.patch"
    with open(os.path.join(out_dir, name), "wb") as fh:
        fh.write(patch)
    return f"{out_dir}/{name}"


def _write_review_set(
    kept: list, patches: list, omitted: set, binary: set, out_dir: str
) -> ReviewSet:
    """Write every surviving patch file plus manifest.tsv into `out_dir`.

    Returns the ReviewSet the caller reports from. The rows never leave this
    function.
    """
    rows: list = []
    # One bucket per manifest token that is not a patch path, keyed by the
    # token written into the row, so a row and its disclosure cannot drift.
    buckets: dict = {"omitted": [], "binary": [], "-": []}
    additions = sum(int(r.get("additions") or 0) for r in kept)
    deletions = sum(int(r.get("deletions") or 0) for r in kept)
    for index, record in enumerate(kept):
        path = record["filename"]
        if patches[index] and index not in omitted:
            patch_file = _write_patch(patches[index], index, out_dir)
        elif index in omitted:
            # Distinct from "-": a patch existed and the budget dropped it.
            # Same situation for the reviewer, different cause, and the
            # prompt documents both tokens.
            patch_file = "omitted"
            buckets[patch_file].append(path)
        elif path in binary:
            # Distinct from "-" in the one way that matters to a reader:
            # there is nothing to open in the working tree either, so the
            # prompt tells the reviewer to leave this row alone instead of
            # spending a turn on a `Read` that must fail.
            patch_file = "binary"
            buckets[patch_file].append(path)
        else:
            patch_file = "-"
            buckets[patch_file].append(path)
        rows.append(
            "\t".join(
                [
                    record["status"],
                    str(int(record.get("changes") or 0)),
                    tsv_field(path),
                    patch_file,
                ]
            )
        )

    with open(
        os.path.join(out_dir, "manifest.tsv"), "w", encoding="utf-8", newline="\n"
    ) as fh:
        fh.writelines(f"{row}\n" for row in rows)
    return ReviewSet(
        buckets["omitted"], buckets["-"], buckets["binary"], additions, deletions
    )


class Request(NamedTuple):
    """What one `--manifest` run was asked to do.

    One named tuple rather than six parameters: the six put
    `write_manifest` over pylint's argument and local-variable limits, and
    `globs` and `budget` next to each other in a positional call is a
    silent-corruption shape -- transposing them is not a type error.
    """

    out_dir: str
    base: str
    head: str
    globs: list
    budget: int
    crosscheck_json: str = ""


def report_conflicts(conflicts: list) -> None:
    """Name the paths where an attribute beat the blob's own content.

    `git diff` called these binary and `sniff_binary` did not, which means
    an attribute reached the diff despite the workflow neutralising them.
    Said loudly, because a pull request able to do this can suppress the
    patch for its own code, and that is a defect in this tool rather than a
    quirk of the change. The review is not lost either way: the row reaches
    the reviewer as `-`, which sends them to open it in the working tree.
    """
    if not conflicts:
        return
    print(
        f"Attribute conflict {len(conflicts)} file(s): git called these"
        " binary and the blob content did not."
    )
    for path in sorted(conflicts):
        print(f"  @ {tsv_field(path)}")


def write_manifest(request: Request) -> int:
    """Write `manifest.tsv` and one patch file per surviving path.

    EVERY FACT IN THE MANIFEST IS COMPUTED FROM GIT, over the range
    `base..head`, which the caller resolves as the merge base and the pull
    request's head. The `pulls/{n}/files` response is used for one thing
    only -- as a second, independent witness to the file list -- and a
    disagreement between the two aborts rather than being reconciled.

    That inversion is the whole point. The file list is the DENOMINATOR the
    coverage check divides by, and the API's list is not fit to be one: it
    caps at 3,000 files and it omits the patch for roughly one file in ten,
    silently, landing the omission on the largest files in a change. On
    2026-10-21 that is how 2,145 changed lines reached a reviewer with no
    diff at all, with nothing anywhere saying so.

    Both sides of the range are a commit, so `additions`, `deletions` and
    the patch bytes all describe the same comparison. The earlier shape
    took counts from the API's three-dot numbers and bytes from a local
    `HEAD^..HEAD`, which could disagree by whatever the base branch had
    itself changed in the same file -- a row reading `changes 2145` beside a
    three-line patch.

    Over `budget`, whole patches are dropped largest-first and their rows
    keep the `omitted` token, so the reviewer still sees that the path
    changed and can open it in the working tree.
    """
    # exist_ok=False on purpose: the workspace is the reviewed repo's own
    # checkout, so silently writing into a directory it already owns would
    # alter the tree under review. A loud failure is the lesser evil, and it
    # goes FIRST so the refusal does not cost a whole diff before it fires.
    os.makedirs(request.out_dir)

    records, conflicts = git_records(request.base, request.head)
    print(f"Range: {request.base}..{request.head}")

    if request.crosscheck_json:
        agreed, message = crosscheck(records, request.crosscheck_json)
        print(message)
        if not agreed:
            return 3
    else:
        print("Crosscheck: not performed; the file list has one witness.")

    report_conflicts(conflicts)

    kept, dropped = _partition(records, request.globs)
    local, _ = local_patches_from_bytes(
        git_diff_bytes(request.base, request.head), request.globs
    )
    patches = [patch_for(r, local) for r in kept]
    binary = {r["filename"] for r in kept if r["binary"]}

    omitted, total = _fit_patches(kept, patches, request.budget)
    written = _write_review_set(kept, patches, omitted, binary, request.out_dir)

    report(dropped)
    report_omitted(written.omitted, request.budget)
    report_binary(written.binary)
    report_unpatched(written.unpatched)
    print(f"Files: {len(kept)}")
    print(f"Additions: {written.additions}")
    print(f"Deletions: {written.deletions}")
    print(f"Patch bytes: {total}")
    return 0


USAGE = (
    "usage: filter_diff.py --manifest <out_dir> <base_rev> <head_rev>"
    " [<files_json>]\n"
    "       filter_diff.py <input_diff> <output_diff>"
)


def main() -> int:
    """Dispatch on argv. Returns the process exit status."""
    argv = sys.argv[1:]

    if argv and argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0

    # A bad budget and a bad argv both exit 2, so they share the one exit
    # rather than each growing its own `return 2`.
    if len(argv) in (4, 5) and argv[0] == "--manifest":
        budget = review_io.checked_budget("MAX_REVIEW_BYTES")
        if budget >= 0:
            try:
                return write_manifest(
                    Request(
                        out_dir=argv[1],
                        base=argv[2],
                        head=argv[3],
                        globs=read_globs(),
                        budget=budget,
                        crosscheck_json=argv[4] if len(argv) == 5 else "",
                    )
                )
            except GitError as exc:
                print(f"filter_diff: {exc}", file=sys.stderr)
                return 4
    elif len(argv) == 2 and not argv[0].startswith("--"):
        return filter_diff(argv[0], argv[1], read_globs())
    else:
        print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
