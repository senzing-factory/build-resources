#!/usr/bin/env python3
"""Print the reviewer's structured findings from a `stream-json` transcript.

    review_text.py <transcript.jsonl>
    review_text.py --events <transcript.jsonl>

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

Exits 0 whatever it finds. Empty output is a fact for the caller to act on,
not an error here.
"""

import json
import sys

import review_io

USAGE = (
    "usage: review_text.py <transcript.jsonl>\n"
    "       review_text.py --events <transcript.jsonl>"
)

# How many events --events prints, newest last. Bounds the job log whatever
# the transcript's size; the workflow used to pass `tail -40`.
EVENT_TAIL = 40


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


def main(argv: list) -> int:
    """Print the structured findings, or with --events the transcript's shape."""
    if len(argv) == 2 and argv[0] == "--events":
        for line in event_lines(argv[1])[-EVENT_TAIL:]:
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
