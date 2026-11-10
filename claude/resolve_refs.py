#!/usr/bin/env python3
# cspell:ignore evilorg  -- the fixture name for a repository swap, not
# vocabulary; test_resolve_refs.sh carries the same directive
"""Turn a pull request's changed `uses:` pins into facts the reviewer can read.

The reviewer's tools are `Read`, `Glob`, `Grep` and two wrappers confined to
the checkout. A pinned-ref diff is therefore the one shape it cannot say
anything true about: both sides are forty opaque characters, and resolving
them needs a network call the model deliberately does not have. This is the
facts-not-capability half of the answer -- it names what to resolve, and
renders what the workflow resolved -- so nothing network-shaped enters the
model's sandbox.

    resolve_refs.py pairs --manifest <manifest.tsv> [--overflow <file>]
                          <base_rev> <head_rev>
        One row per pin whose ref CHANGED, that was ADDED, or that was
        REMOVED AND REPLACED, deduplicated across the files carrying it:

            repo <TAB> subpath <TAB> old_ref <TAB> new_ref <TAB> comment
            <TAB> files

        An empty old_ref means the pin is new; an empty new_ref means it is
        gone. `comment` is the `# ...` text on the added line: a hash pin
        states the version it claims to be there and nowhere else, so it is
        the only thing a truthfulness check has to compare against the tags
        the lookup returns. `--overflow` takes the notice for pins past
        MAX_PINS, which belongs where the model reads rather than only in a
        runner log.

    resolve_refs.py render --facts <facts.tsv> [--disclosure <file>]
        The prompt block on stdout, and a "could not resolve" one-liner into
        `--disclosure` for the comment's own disclosure section. Facts rows
        are written by the workflow after its lookups:

            repo <TAB> subpath <TAB> side <TAB> ref <TAB> status <TAB> sha
            <TAB> date <TAB> reach <TAB> tags <TAB> branches <TAB> comment

WHAT IS AND IS NOT A SIGNAL, MEASURED RATHER THAN ASSUMED. Across 206 hash
pins resolvable from recent pull requests in this fleet, 13 sat on a commit
that is NOT an ancestor of its repository's default branch -- `actions/checkout`,
`actions/setup-java` and `azure/login` among them, because an action that
commits a built `dist/` tags its releases off the mainline. So "not an
ancestor" alone is the NORMAL state for a tagged release, and rendering it as
a warning would raise a blocker on most dependency bumps in the fleet.

TWO FACTS ARE EMPHASISED; EVERYTHING ELSE IS STATED FLAT. A pin whose `uses:`
moved to a DIFFERENT REPOSITORY, and a pin whose trailing `# vX` comment
names no tag that points at the commit. Each is a claim the diff itself makes
that the resolved facts can contradict, and neither is under the control of
whoever owns the repository being pinned. The absence of tag, branch head and
ancestry TOGETHER is noted where it occurs but not emphasised: all three are
properties of a repository an attacker would own, so one `git push` clears
them, and a signal the subject can clear detects an accident rather than an
attack.

EVERY FIELD THAT REACHES THE PROMPT IS VALIDATED, NOT ESCAPED. Action names
and refs come from the pull request's own diff, and tag and branch names come
from a third-party repository, so all of them are attacker-controlled on a
fork pull request -- the hazard issue #332 is about. A value that does not
match its character class is DROPPED, never quoted: there is no escaping rule
to get subtly wrong, and a dropped pin still surfaces as one that could not be
resolved rather than as silence. The classes also reject `.` and `..` as whole
path segments, because every one of these values is interpolated into an API
URL path and a dot segment resolves against it.
"""

import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import review_io  # noqa: E402  pylint: disable=wrong-import-position

# A `uses:` line on either side of a diff. The optional `-` after the
# indentation is the YAML list dash, present on a step's `uses:` and absent on
# a job's; without it every step-level pin in the fleet is missed.
USES = re.compile(r"^([+-])\s*(?:-\s+)?uses:\s*[\"']?([^\"'\s@]+)@([^\s\"'#]+)")

# The post-image path of the file a hunk belongs to, so one pin can report
# how many files carry it rather than how many diff lines mention it. NON-
# GREEDY: a path can itself contain ` b/`, and a greedy `.*` then takes the
# LAST one, which collapses two such paths to the same tail and counts two
# files as one.
DIFF_HEADER = re.compile(r"diff --git a/.*? b/(.*)")

# The trailing `# v4` on a hash pin, taken from the ADDED line only.
COMMENT = re.compile(r"#\s*(\S+)")

# Character classes, deliberately narrow, and matched with `fullmatch` rather
# than a `$` anchor -- `$` also matches before a trailing newline, which is
# exactly the character these classes exist to keep out of a TSV row.
# A path segment is GitHub's own owner and repository rule; a ref adds `/`
# and `+` for `release/1.x` and `1.0+build`.
SEGMENT = re.compile(r"[A-Za-z0-9._-]{1,100}")
REF = re.compile(r"[A-Za-z0-9._/+-]{1,255}")
SHA = re.compile(r"[0-9a-f]{40}")
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")

# Neither `.` nor `..` is a usable owner, repository, tag or branch, and both
# are meaningful to a URL path: `repos/o/r/commits/../../../../rate_limit`
# normalises to another endpoint entirely before it is sent.
DOTS = (".", "..")

# The cap on pins resolved in one run. A pull request that rewrites every
# workflow is real, and each pin costs several lookups; past this the block
# says how many were left over, which is bounded and honest.
MAX_PINS = 25

# How many tag or branch names one ref's line will name before it stops.
MAX_NAMES = 6

STATUS = {
    "ok": "",
    "no-such-commit": "**does not exist in that repository**",
    "no-such-repo": (
        "could not be read (private, renamed, deleted, or behind an IP allow list)"
    ),
    "lookup-failed": "could not be resolved (the lookup failed)",
}

REACH = {
    "on-default": "an ancestor of the default branch",
    "off-default": "not an ancestor of the default branch",
    "unknown": "ancestry unknown",
}

USAGE = (
    "usage: resolve_refs.py pairs --manifest <manifest.tsv>"
    " [--overflow <file>] <base> <head>\n"
    "       resolve_refs.py render --facts <facts.tsv> [--disclosure <file>]"
)


def _flag(argv: list, name: str, default: str = "") -> str:
    """The value after `name`, or `default`."""
    return argv[argv.index(name) + 1] if name in argv else default


def is_segment(value: str) -> bool:
    """A usable owner or repository name, with no dot segment."""
    return value not in DOTS and SEGMENT.fullmatch(value) is not None


def is_ref(value: str) -> bool:
    """A usable ref, tag or branch name, with no empty or dot segment."""
    if REF.fullmatch(value) is None:
        return False
    return all(part not in ("",) + DOTS for part in value.split("/"))


def split_action(action: str):
    """(repo, subpath) for a `uses:` target, or None if there is none to ask about.

    A local action (`./x`) and a container (`docker://x`) have no repository
    to ask an API about, and sending one produces a 404 the reviewer would be
    told is a commit that does not exist. The scheme test is belt and braces:
    SEGMENT already rejects `docker:` for its colon. The leading-`.` test is
    not -- `./.github/actions/x` is all valid segments.
    """
    if action.startswith(".") or "://" in action:
        return None
    parts = action.split("/")
    if len(parts) < 2 or not all(is_segment(p) for p in parts):
        return None
    return "/".join(parts[:2]), "/".join(parts[2:])


def scan(diff: str) -> dict:
    """{(repo, subpath): {"-": refs, "+": refs, "comment": str, "files": set}}.

    Both sides are sets because one pin appears in many workflow files at
    once, and an `actions/checkout` bump that touched ten of them is one fact
    to resolve, not ten.
    """
    found: dict = {}
    where = ""
    for line in diff.splitlines():
        header = DIFF_HEADER.fullmatch(line)
        if header:
            where = header.group(1)
            continue
        match = USES.match(line)
        if not match:
            continue
        side, action, ref = match.groups()
        key = split_action(action)
        if key is None or not is_ref(ref):
            continue
        entry = found.setdefault(
            key, {"-": set(), "+": set(), "comment": "", "files": set()}
        )
        entry[side].add(ref)
        entry["files"].add(where)
        if side == "+" and not entry["comment"]:
            note = COMMENT.search(line)
            if note and is_ref(note.group(1)):
                entry["comment"] = note.group(1)
    return found


def changed(found: dict) -> list:
    """The rows `pairs` prints: one per pin whose ref moved or that is new.

    PLUS THE REMOVAL HALF OF A REPOSITORY SWAP. Keying by `(repo, subpath)`
    means `actions/checkout` becoming `evilorg/checkout` is two keys, not
    one: the old key loses its new side and the new key has no old side, so
    without this the swap renders as a brand new pin and the block then
    vouches for the repository that displaced the one we trusted.

    An UNPAIRED removal is left out on purpose. The reviewer can already see
    a deleted `uses:` line in the patch it was given, so resolving it buys
    no fact the model lacks while spending lookups and the MAX_PINS budget.
    """
    replaced = {
        (repo.split("/")[-1], subpath)
        for (repo, subpath), entry in found.items()
        if entry["+"] and not entry["-"]
    }
    rows = []
    for (repo, subpath), entry in sorted(found.items()):
        old, new = entry["-"], entry["+"]
        if old == new:
            continue
        if not new:
            if len(old) != 1 or (repo.split("/")[-1], subpath) not in replaced:
                continue
            rows.append(
                (repo, subpath, next(iter(old)), "", "", str(len(entry["files"])))
            )
            continue
        # One ref on the new side is the shape worth resolving. Several
        # distinct new refs for one action means the files disagree with each
        # other, which the model can see in the patches without help here.
        if len(new) != 1:
            continue
        new_ref = next(iter(new))
        old_ref = next(iter(old)) if len(old) == 1 else ""
        if old_ref == new_ref:
            continue
        rows.append(
            (
                repo,
                subpath,
                old_ref,
                new_ref,
                entry["comment"],
                str(len(entry["files"])),
            )
        )
    return rows


def pairs(manifest: str, base: str, head: str, overflow: str = "") -> int:
    """Print one row per changed, added or replaced pin in `base..head`.

    YAML ONLY, and `:(literal)` on every pathspec. A `uses:` key is legal in a
    workflow and in a composite action and nowhere else, so the filter bounds
    the diff a pull request can make this program read; and without the magic
    prefix git reads a path containing `*` or `[` as a GLOB, which would pull
    in files the review manifest does not contain.
    """
    paths = [
        f":(literal){path}"
        for status, path, _ in review_io.read_manifest(manifest)
        if status != review_io.REMOVED and path.endswith((".yml", ".yaml"))
    ]
    if not paths:
        return 0
    result = subprocess.run(
        ["git", "diff", "--no-color", "-U0", base, head, "--", *paths],
        check=False,
        capture_output=True,
        text=True,
        errors="replace",
    )
    # A FAILED DIFF AND AN EMPTY ONE PRINT THE SAME NOTHING, and a caller
    # that reads the status as output would publish "no pins changed" for
    # either -- the silent blindness this whole step exists to end.
    if result.returncode != 0:
        detail = " ".join(result.stderr.split())[:200]
        sys.stderr.write(f"git diff failed ({result.returncode}): {detail}\n")
        return 1
    rows = changed(scan(result.stdout))
    for row in rows[:MAX_PINS]:
        print("\t".join(row))
    if len(rows) > MAX_PINS:
        note = (
            f"{len(rows) - MAX_PINS} further changed action pin(s) were not"
            f" resolved: this run resolves at most {MAX_PINS}"
        )
        sys.stderr.write(f"{note}\n")
        if overflow:
            with open(overflow, "w", encoding="utf-8") as handle:
                handle.write(note)
    return 0


def _names(field: str) -> list:
    """The validated names in a comma-separated list, capped WITH its count.

    The count is the point: six tags and a silent cut read as the whole
    truth about which tags point at a commit, which is the question the
    `# vX` comment is checked against.
    """
    names = [name for name in field.split(",") if is_ref(name)]
    if len(names) <= MAX_NAMES:
        return names
    return names[:MAX_NAMES] + [f"(+{len(names) - MAX_NAMES} more)"]


def _quoted(names: list) -> str:
    """Names in backticks, leaving `_names`' own `(+N more)` marker plain."""
    return ", ".join(n if n.startswith("(+") else f"`{n}`" for n in names)


# Where each field sits in a facts row. Named rather than unpacked: the row
# is eleven columns wide and positional unpacking put `read_facts` over
# pylint's local-variable limit while telling a reader nothing.
COLUMNS = {
    "repo": 0,
    "subpath": 1,
    "side": 2,
    "ref": 3,
    "status": 4,
    "sha": 5,
    "date": 6,
    "reach": 7,
    "tags": 8,
    "branches": 9,
    "comment": 10,
}


def _at(fields: list, name: str) -> str:
    """One column of a facts row, or "" when the row is short."""
    index = COLUMNS[name]
    return fields[index] if index < len(fields) else ""


def read_facts(path: str) -> dict:
    """{(repo, subpath): {side: fact}} from the workflow's resolved rows.

    This is where the validation promised in the module docstring is
    enforced: a row whose repository, ref or SHA fails its class is dropped
    rather than rendered.
    """
    out: dict = {}
    if not path or not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < len(COLUMNS) - 1:
                continue
            repo, subpath = _at(fields, "repo"), _at(fields, "subpath")
            side, ref = _at(fields, "side"), _at(fields, "ref")
            if split_action(f"{repo}/{subpath}".rstrip("/")) is None:
                continue
            if not is_ref(ref) or side not in ("old", "new"):
                continue
            out.setdefault((repo, subpath), {})[side] = _fact(fields, ref)
    return out


def _fact(fields: list, ref: str) -> dict:
    """One validated fact from one facts row."""
    sha, date = _at(fields, "sha"), _at(fields, "date")
    status, reach = _at(fields, "status"), _at(fields, "reach")
    comment = _at(fields, "comment")
    return {
        "ref": ref,
        "status": status if status in STATUS else "lookup-failed",
        "sha": sha if SHA.fullmatch(sha) else "",
        "date": date[:10] if DATE.match(date) else "",
        "reach": reach if reach in REACH else "unknown",
        "tags": _names(_at(fields, "tags")),
        "branches": _names(_at(fields, "branches")),
        "comment": comment if is_ref(comment or "x") else "",
    }


def describe(fact: dict) -> str:
    """One line about one resolved ref, or about why it is not resolved."""
    if fact["status"] != "ok":
        return f"`{fact['ref']}` {STATUS[fact['status']]}."
    bits = []
    bits.append(
        "tagged " + _quoted(fact["tags"]) if fact["tags"] else "no tag points at it"
    )
    if fact["branches"]:
        bits.append("heads " + _quoted(fact["branches"]))
    bits.append(REACH[fact["reach"]])
    if fact["date"]:
        bits.append(f"committed {fact['date']}")
    line = f"`{fact['sha'][:12] or fact['ref']}`: " + "; ".join(bits) + "."
    if fact["comment"]:
        line += (
            f" The line's `# {fact['comment']}` comment names a tag here."
            if fact["comment"] in fact["tags"]
            else (
                f" **The line's `# {fact['comment']}` comment names no tag at"
                " this commit.**"
            )
        )
    return line


def orphan(fact: dict) -> bool:
    """No tag, no branch head, no ancestry -- stated where it occurs.

    NOT emphasised: see the module docstring. Every leg of this conjunction
    is a property of the repository being pinned, so whoever controls it can
    clear all three with one push, and what survives is a detector for an
    accident rather than for an attack.
    """
    return (
        fact["status"] == "ok"
        and not fact["tags"]
        and not fact["branches"]
        and fact["reach"] == "off-default"
    )


def _name(key: tuple) -> str:
    """`owner/repo` or `owner/repo/subpath` for a facts key."""
    return f"{key[0]}/{key[1]}" if key[1] else key[0]


def replacements(facts: dict) -> dict:
    """{addition key: the removal key it replaces}.

    Paired on the repository's SECOND PATH SEGMENT, which is the look-alike
    swap this exists for: `actions/checkout` out, `evilorg/checkout` in. The
    name a human recognises is the second segment, and the owner is the half
    that changed.
    """
    gone: dict = {}
    for key, sides in sorted(facts.items()):
        if "old" in sides and "new" not in sides:
            gone.setdefault((key[0].split("/")[-1], key[1]), []).append(key)
    out = {}
    for key, sides in sorted(facts.items()):
        if "new" not in sides or "old" in sides:
            continue
        waiting = gone.get((key[0].split("/")[-1], key[1]))
        if waiting:
            out[key] = waiting.pop(0)
    return out


def _head(key: tuple, sides: dict, counterpart: str) -> str:
    """The `- ...` line that opens one action's group.

    A swap NEVER opens with `newly pinned`. That phrase is what makes the
    block read as a routine addition, and it is the half of the rendering
    an attacker would be relying on.
    """
    name = _name(key)
    old, new = sides.get("old"), sides.get("new")
    if old and new:
        return f"- `{name}`: `{old['ref']}` -> `{new['ref']}`"
    if new:
        if counterpart:
            return f"- `{name}`: replaces `{counterpart}`"
        return f"- `{name}`: newly pinned"
    if counterpart:
        return f"- `{name}`: pin removed, replaced by `{counterpart}`"
    return f"- `{name}`: pin removed"


def render(facts: dict) -> list:
    """The prompt block's lines, one group per action."""
    swaps = replacements(facts)
    succeeded_by = {removed: added for added, removed in swaps.items()}
    lines = []
    for key, sides in sorted(facts.items()):
        old, new = sides.get("old"), sides.get("new")
        counterpart = swaps.get(key) or succeeded_by.get(key)
        lines.append(_head(key, sides, _name(counterpart) if counterpart else ""))
        if key in swaps:
            lines.append(
                f"  - **The `uses:` changed repository: `{_name(swaps[key])}`"
                f" replaced by `{_name(key)}`.**"
            )
        if old:
            lines.append(f"  - was {describe(old)}")
        if new:
            lines.append(f"  - now {describe(new)}")
        if new and orphan(new):
            # The INTERPRETATION only: `describe` has already stated all
            # three legs on the line above, and repeating them is the kind
            # of prose that buries the one clause a reader needed.
            lines.append(
                "  - That combination is the shape of a commit that exists"
                " only on a fork or an unmerged branch."
            )
        if old and new and old["date"] and new["date"] and new["date"] < old["date"]:
            lines.append("  - **The new pin is OLDER than the one it replaces.**")
    return lines


def unresolved(facts: dict) -> list:
    """`owner/repo@ref (why)` for every side that did not resolve."""
    out = []
    for key, sides in sorted(facts.items()):
        name = _name(key)
        for side in ("new", "old"):
            fact = sides.get(side)
            if fact and fact["status"] != "ok":
                out.append(f"`{name}@{fact['ref']}` ({STATUS[fact['status']]})")
    return out


def main(argv: list) -> int:
    """Dispatch, or print usage on anything else."""
    if argv[:1] in (["-h"], ["--help"]):
        print(USAGE)
        return 0
    if argv[:1] == ["pairs"] and len(argv) >= 5:
        return pairs(
            _flag(argv, "--manifest"),
            argv[-2],
            argv[-1],
            _flag(argv, "--overflow"),
        )
    if argv[:1] == ["render"]:
        facts = read_facts(_flag(argv, "--facts"))
        body = render(facts)
        if body:
            print("\n".join(body))
        disclosure = _flag(argv, "--disclosure")
        if disclosure:
            with open(disclosure, "w", encoding="utf-8") as handle:
                handle.write(", ".join(unresolved(facts)))
        return 0
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
