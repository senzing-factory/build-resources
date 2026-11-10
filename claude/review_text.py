#!/usr/bin/env python3
"""Print the reviewer's structured findings from a `stream-json` transcript.

    review_text.py <transcript.jsonl>
    review_text.py --events <transcript.jsonl>
    review_text.py --telemetry <transcript.jsonl>

The workflow runs the reviewer with `--output-format stream-json --verbose`,
so stdout is the run's transcript and not the review, and with
`--json-schema`, so the review itself is a VALIDATED JSON OBJECT rather than
prose. This recovers that object: the `structured_output` field of the LAST
`result` event in the stream, printed as one line of JSON.

WHY THE TWO FLAGS COMPOSE, since the whole design rests on it. `--json-schema`
does not replace the transcript and does not change the output format: it
registers one additional tool, `StructuredOutput`, which the model calls once
at the end of its turn, and the validated object is attached to the terminal
`result` event as `structured_output`. Every `tool_use`/`tool_result` pair the
coverage measurement counts is emitted exactly as before. Established from the
CLI's own code at the pinned version (2.1.310): the only constraint declared on
`--json-schema` is `--print`, and the validation that couples flags to
`--output-format stream-json` names `--include-partial-messages`,
`--forward-subagent-text` and `--prompt-suggestions` -- not this one.

Why the LAST result and not the first: a resumed or retried turn emits
another, and the one that produced the comment is the one that finished.

Why an `is_error` result yields NOTHING, even when an earlier result in the
same stream carried an object: the CLI ends a run itself on a turn limit, a
refusal or an API failure, and what it leaves is a diagnostic. The last result
is the run's verdict, so an error one is not skipped over in favour of an
earlier success.

THERE IS NO TEXT FALLBACK, and its absence is deliberate. The previous version
of this program fell back to the last assistant text block when the stream held
no `result` event, because the review WAS that text. It is not any more: under
the schema the model's findings exist only as the tool call's argument, and an
assistant text block is at best commentary. Recovering it would hand
review_output.py something it cannot read, which the workflow would then report
as a review that did not conform -- the same outcome as recovering nothing, one
misleading step later.

A line that does not parse is skipped. A truncated transcript -- what a killed
run leaves -- then yields the last complete event, or nothing, and nothing is
the safe direction.

`--events` prints one line per transcript event describing only its SHAPE: the
event type, and for a message the tool names it called or whether a tool result
was an error. No content, ever. The workflow uses it where it used to `tail`
the raw transcript into the job log, which on a public repository published
whole file contents out of every `Read` result.

`--telemetry` prints the run's OCCUPANCY, as `key: value` lines for the job
summary. It exists because the one thing the reviewer's own output cannot
say is how close the run came to its context window, and four measured
invocations showed that is what decides coverage: the same 48 rows and the
same 305,850 patch bytes scored 48 of 48 at a peak occupancy of 211,948
tokens and 24 of 48 when the window was constrained, ending on
`terminal_reason: rapid_refill_breaker` with three compactions and no
structured output. Row counts and patch bytes discriminated nothing between
those two runs; the window did. None of it survived the run -- the
transcript is a `$RUNNER_TEMP` file nothing uploads.

`.model` is the single most valuable line. The `model` input defaults to
the empty string, which is the CLI's own undocumented default, so without
this nobody can say which model reviewed anything.

NUMBERS AND CLI ENUMS ONLY, never content. The reviewer reads the pull
request's files, so a mode that printed anything derived from them would
publish them into a public job log -- the exact defect `--events` was
written to close. Every string that leaves here is a model id or a CLI
stop/terminal reason, and each one goes through `_token`, which keeps
`[A-Za-z0-9._:/-]` and nothing else: the summary is rendered as markdown,
so an unsanitised string is an injection into the page as well as a leak.

IT READS THE LAST `result` EVENT WHETHER OR NOT IT IS AN ERROR, which is the
deliberate difference from `structured_output` above. An errored result is
worthless as a review and is the most valuable telemetry in the file: it is
the one that carries the turn count and the terminal reason for the run that
did not finish. The occupancy and compaction counts are computed from
whatever events exist, so a transcript with no `result` at all still reports
them.

Exits 0 whatever it finds. Empty output is a fact for the caller to act on,
not an error here.
"""

import json
import sys

import review_io

USAGE = (
    "usage: review_text.py <transcript.jsonl>\n"
    "       review_text.py --events <transcript.jsonl>\n"
    "       review_text.py --telemetry <transcript.jsonl>"
)

# How many events --events prints, newest last. Bounds the job log whatever
# the transcript's size; the workflow used to pass `tail -40`.
EVENT_TAIL = 40

# The only characters a telemetry string may carry. Model ids and the CLI's
# stop/terminal reasons are drawn from this set; anything else means the
# field is not what it is supposed to be, and the summary it is written to
# is rendered as markdown.
TOKEN_SAFE = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"
)

# Longest telemetry string printed. A model id is ~30 characters; a cap
# bounds the summary whatever the transcript claims.
TOKEN_LIMIT = 64

# How many `window:` lines --telemetry prints. One per model the run billed,
# which is normally one; the bound stops a malformed `modelUsage` becoming
# an unbounded write to the job summary.
WINDOW_LIMIT = 8


def _events(path: str):
    """Every parsable JSON object in the transcript, in order.

    A line that does not parse yields None rather than being skipped, so
    `--events` can report it. See review_io.json_lines for why a truncated
    transcript must not be fatal.
    """
    for event in review_io.json_lines(path):
        yield event if isinstance(event, dict) else None


def structured_output(path: str):
    """The `structured_output` of the last `result` event, or None.

    None covers all three ways there can be no review: no `result` event at
    all (a killed or timed-out run), a result the CLI marked `is_error`, and
    a result carrying no structured output -- which is what the CLI leaves
    when the model never called the tool, or called it and could not satisfy
    the schema within its retry budget. The caller must not be able to tell
    those apart by accident: every one of them means nothing was adjudicated.
    """
    found = None
    for event in _events(path):
        if event is None or event.get("type") != "result":
            continue
        if event.get("is_error"):
            found = None
            continue
        value = event.get("structured_output")
        found = value if isinstance(value, dict) else None
    return found


def _tool_names(event: dict) -> str:
    """A shape description of one message's blocks. Never any content."""
    message = event.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind == "tool_use":
            name = block.get("name")
            parts.append(f"tool_use:{name if isinstance(name, str) else '?'}")
        elif kind == "tool_result":
            parts.append(
                "tool_result:error" if block.get("is_error") else "tool_result:ok"
            )
        elif kind == "text":
            parts.append(f"text:{len(block.get('text') or '')}c")
        elif isinstance(kind, str):
            parts.append(kind)
    return " ".join(parts)


def event_lines(path: str) -> list:
    """One shape line per event: type, subtype, and block shapes."""
    lines = []
    for event in _events(path):
        if event is None:
            lines.append("<unparsable line>")
            continue
        kind = str(event.get("type") or "?")
        subtype = event.get("subtype")
        head = f"{kind}/{subtype}" if isinstance(subtype, str) else kind
        if kind == "result":
            head += " is_error" if event.get("is_error") else " ok"
            value = event.get("structured_output")
            head += " structured" if isinstance(value, dict) else " unstructured"
        detail = _tool_names(event)
        lines.append(f"{head} {detail}".rstrip())
    return lines


def _token(value) -> str:
    """One telemetry string, reduced to TOKEN_SAFE, or `-`.

    A disallowed character becomes `?` rather than being dropped, so a
    field that is not what it claims to be is visible as a mangled value
    instead of a plausible shorter one. Anything that is not a non-empty
    string is `-`, which is how every field here says "not present".
    """
    if not isinstance(value, str) or not value:
        return "-"
    return "".join(c if c in TOKEN_SAFE else "?" for c in value[:TOKEN_LIMIT])


def _whole(value) -> str:
    """A non-negative integer as itself, or `-`.

    `bool` is an `int` in Python, so it is excluded explicitly: a `True`
    printed as `1` would read as a measurement.
    """
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return "-"
    return str(value)


def _usage_total(event: dict):
    """One assistant turn's occupancy, or None if it reported none.

    Occupancy is what the model was holding when the API served that turn:
    the fresh input plus both halves of the cache, because a cached token
    occupies the window exactly as a fresh one does. Output tokens are not
    counted -- they are not in the window when the request is made.

    None rather than 0 for a turn with no `usage`, so a run that died
    before its first assistant message reports `-` rather than a measured
    zero. A `usage` whose fields are absent or malformed IS a measured
    zero: the turn happened and reported nothing countable.
    """
    message = event.get("message")
    usage = message.get("usage") if isinstance(message, dict) else None
    if not isinstance(usage, dict):
        return None
    total = 0
    for field in (
        "input_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
    ):
        value = usage.get(field)
        if isinstance(value, int) and not isinstance(value, bool) and value > 0:
            total += value
    return total


def _window_lines(result: dict) -> list:
    """One `window:` line per model in the result's `modelUsage`.

    The context window and output cap are reported PER MODEL and never
    reconciled with `.model` from the init event, because choosing between
    them when they disagree would be a guess presented as a measurement.
    Sorted so two runs of the same shape produce the same summary.
    """
    usage = result.get("modelUsage")
    if not isinstance(usage, dict):
        return []
    lines = []
    for name in sorted(usage)[:WINDOW_LIMIT]:
        entry = usage[name] if isinstance(usage[name], dict) else {}
        lines.append(
            f"window: {_token(name)}"
            f" context={_whole(entry.get('contextWindow'))}"
            f" max_output={_whole(entry.get('maxOutputTokens'))}"
        )
    return lines


def telemetry_lines(path: str) -> list:
    """The run's occupancy as `key: value` lines. Never any content.

    A missing transcript is an empty list, not an exception: this runs on
    the failure paths, including the ones where the CLI never wrote a
    transcript at all, and it must not be the thing that fails the job.
    See review_io.json_lines for why a truncated one is not fatal either.
    """
    model, peak, compactions, result = None, None, 0, None
    try:
        events = list(_events(path))
    except OSError as problem:
        print(f"review_text: no transcript to summarise ({problem})", file=sys.stderr)
        return []
    for event in events:
        if event is None:
            continue
        kind = event.get("type")
        if kind == "system":
            subtype = event.get("subtype")
            if subtype == "compact_boundary":
                compactions += 1
            elif subtype == "init" and model is None:
                model = event.get("model")
        elif kind == "assistant":
            total = _usage_total(event)
            if total is not None and (peak is None or total > peak):
                peak = total
        elif kind == "result":
            result = event
    result = result if isinstance(result, dict) else {}
    cost = result.get("total_cost_usd")
    if isinstance(cost, bool) or not isinstance(cost, (int, float)):
        cost = "-"
    else:
        cost = f"{cost:.4f}"
    return [
        f"model: {_token(model)}",
        f"num_turns: {_whole(result.get('num_turns'))}",
        f"stop_reason: {_token(result.get('stop_reason'))}",
        f"terminal_reason: {_token(result.get('terminal_reason'))}",
        f"total_cost_usd: {cost}",
        f"compact_boundaries: {compactions}",
        f"peak_context_tokens: {_whole(peak)}",
    ] + _window_lines(result)


def main(argv: list) -> int:
    """Print the structured findings, or the transcript's shape or occupancy."""
    if len(argv) == 2 and argv[0] == "--events":
        for line in event_lines(argv[1])[-EVENT_TAIL:]:
            print(line)
        return 0
    if len(argv) == 2 and argv[0] == "--telemetry":
        for line in telemetry_lines(argv[1]):
            print(line)
        return 0
    if len(argv) != 1 or argv[0].startswith("--"):
        print(USAGE, file=sys.stderr)
        return 2
    found = structured_output(argv[0])
    if found is None:
        print(
            "review_text: the transcript carries no structured output; the"
            " reviewer produced nothing that can be adjudicated",
            file=sys.stderr,
        )
        return 0
    json.dump(found, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
