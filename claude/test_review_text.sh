#!/usr/bin/env bash
# cspell:ignore jsonl rrun erun  -- test fixture / local constant names
# Fixture tests for review_text.py. No framework: builds a Claude Code
# stream-json transcript, runs the extractor, and checks what came out.
#
# WHAT THIS PROGRAM IS. The workflow runs the reviewer with
# `--output-format stream-json --verbose`, so stdout is the run's TRANSCRIPT
# and not the review, and with `--json-schema`, so the review itself is a
# VALIDATED JSON OBJECT rather than prose. This recovers that object: the
# `structured_output` field of the LAST `result` event, printed as one line of
# JSON for review_output.py to adjudicate.
#
# THERE IS NO TEXT FALLBACK, and asserting its absence is the point of half
# this file. The previous version of this program fell back to the last
# assistant text block when the stream held no `result` event, because the
# review WAS that text. It is not any more: under the schema the findings
# exist only as the tool call's argument, and an assistant text block is at
# best commentary. Recovering it would hand review_output.py something it
# cannot read, which the workflow would then report as a review that did not
# conform -- the same outcome as recovering nothing, one misleading step
# later. So a transcript full of plausible review prose and no tool call must
# produce NOTHING, and the fixtures below make that prose as tempting as the
# real thing.
#
# THE FAILURE THAT MATTERS MOST is the last block: a terminal event with
# `is_error: true` and `subtype: "error_max_turns"` carrying no structured
# output. It must not be confused with a clean review, which is an empty
# `findings` array that the model had to produce. One adjudicated nothing and
# the other adjudicated everything and found nothing; they differ here by
# "empty stdout" against `{"findings": []}`, and downstream by a comment
# saying the check could not run against one saying there are no blocking
# findings. Both halves are asserted.
#
# Plus --events, which replaced a `tail` of the raw transcript in the job log.
# A tool result carries whole file contents, so that tail published source
# files into a public job log; the fixture asserts the content is NOT there.
#
# Usage:  ./test_review_text.sh        # from anywhere; exits non-zero on failure
#
# SC2016 is disabled for the file, and only SC2016. Several fixtures are
# transcripts holding the markdown the DELETED contract produced, which is
# full of backticked paths and `- **BLOCKER**` bullets; shellcheck reads those
# backticks as command substitution it is warning you will not happen. It will
# not happen, and that is the point -- they are literal review prose under
# test, asserted NOT to be recovered.
# shellcheck disable=SC2016
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/review_text.py"
OUTPUT="$HERE/review_output.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok    $1"
  else
    echo "  FAIL  $1: expected '$2', got '$3'" >&2
    FAILED=1
  fi
}

# stdout only. The program explains an empty result on stderr, and a suite
# that let that through would print the explanation between its own ok lines
# on every one of the dozen fixtures that produce nothing.
rrun() { python3 "$SCRIPT" "$WORK/$1" 2>/dev/null; }
erun() { python3 "$SCRIPT" --events "$WORK/$1"; }
stderr_of() { { python3 "$SCRIPT" "$WORK/$1" >/dev/null; } 2>&1; }

# One finding, as the CLI attaches it to the terminal event after validating
# the model's tool call against claude/review-schema.json.
FINDING='{"severity":"BLOCKER","path":"pkg/real.go","line":3,"message":"Unvalidated input reaches the query builder — validate it."}'

echo "review_text.py"

# A normal run: system init, an assistant turn with a tool call whose result
# carries a file body, and the terminal result carrying the findings.
{
  printf '%s\n' '{"type":"system","subtype":"init","model":"claude"}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/w/pkg/real.go"}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"package main // SECRET_FILE_BODY"}]}}'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"findings":['"$FINDING"']}}'
} > "$WORK/normal.jsonl"
check "the result event's structured output is what gets emitted" \
  '{"findings": [{"severity": "BLOCKER", "path": "pkg/real.go", "line": 3, "message": "Unvalidated input reaches the query builder — validate it."}]}' \
  "$(rrun normal.jsonl)"
# `ensure_ascii=False`, so a finding written with an em dash or any other
# non-ASCII character reaches review_output.py as itself rather than as a
# `—` escape that would be printed literally into the comment.
check "non-ASCII in a message survives as itself, not as an escape" \
  '0' "$(rrun normal.jsonl | grep -c 'u2014' || true)"
check "it is one line, which is what the workflow redirects to a file" \
  '1' "$(rrun normal.jsonl | wc -l | tr -d ' ')"
check "nothing else from the transcript comes with it" \
  '0' "$(rrun normal.jsonl | grep -c 'SECRET_FILE_BODY' || true)"

# The last result wins: a resumed or retried turn emits another, and the one
# that finished is the one that produced the review.
{
  cat "$WORK/normal.jsonl"
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"findings":[]}}'
} > "$WORK/resumed.jsonl"
check "the LAST result wins over an earlier one" \
  '{"findings": []}' "$(rrun resumed.jsonl)"

# ---------------------------------------------------------------------------
# THERE IS NO TEXT FALLBACK
# ---------------------------------------------------------------------------
#
# Each of these transcripts holds text that reads exactly like the review the
# old contract asked for. Under the schema none of it is a review: the
# findings exist only as the tool call's validated argument.

# No result event at all -- a killed run. The model's prose is in the
# transcript and must stay there.
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"first pass"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"**1 finding** — 1 blocker, 0 risks.\n- **BLOCKER** `pkg/real.go:3` — unvalidated input."}]}}'
} > "$WORK/noresult.jsonl"
check "with no result event nothing is emitted" '' "$(rrun noresult.jsonl)"
check "and the assistant's prose is not recovered as a review" \
  '0' "$(rrun noresult.jsonl | grep -c 'BLOCKER' || true)"
check "the reason is on stderr, where it cannot reach the comment" \
  '1' "$(stderr_of noresult.jsonl | grep -c 'carries no structured output')"

# A result event that carries prose in `result` and no structured output.
# This is the exact shape the deleted contract produced, so it is the one a
# half-migrated CLI or a model that ignored the tool would leave -- and
# posting it would put a review under a heading while nothing validated it.
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"**No blocking findings.** 1 file, +1/-1."}'
} > "$WORK/prose_result.jsonl"
check "a result carrying prose instead of an object emits nothing" \
  '' "$(rrun prose_result.jsonl)"
check "and the prose verdict is not mistaken for a clean review" \
  '0' "$(rrun prose_result.jsonl | grep -c 'No blocking findings' || true)"

# `structured_output` that is not an object is not an object. A list, a
# string or a null is the CLI telling us something other than a review, and
# coercing any of them is how a guess becomes a comment.
for shape in '[]' '"findings"' 'null' '0'; do
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":'"$shape"'}' \
    > "$WORK/shape.jsonl"
  check "structured_output of $shape yields nothing" '' "$(rrun shape.jsonl)"
done

# A later result with no structured output REPLACES an earlier one that had
# it. The last result is the run's verdict; stepping back to an earlier
# success would report findings the finished run did not stand behind.
{
  cat "$WORK/normal.jsonl"
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
} > "$WORK/unstructured_last.jsonl"
check "a later result with no object does not fall back to an earlier one" \
  '' "$(rrun unstructured_last.jsonl)"

# ---------------------------------------------------------------------------
# AN ERRORED RUN IS NOT A CLEAN REVIEW
# ---------------------------------------------------------------------------
#
# The CLI ends a run itself on a turn limit, a refusal or an API failure, and
# what it leaves is a diagnostic. A clean review is `{"findings": []}`, which
# the model had to produce by calling the tool. One adjudicated nothing; the
# other adjudicated everything and found nothing. They must never collapse
# into each other, in either direction.

printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"findings":[]}}' \
  > "$WORK/clean.jsonl"
printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Error: exceeded max turns"}' \
  > "$WORK/maxturns.jsonl"

check "a clean review is an empty findings array, not an empty stream" \
  '{"findings": []}' "$(rrun clean.jsonl)"
check "a clean review says nothing on stderr" '' "$(stderr_of clean.jsonl)"
check "error_max_turns with no structured output emits nothing at all" \
  '' "$(rrun maxturns.jsonl)"
check "and says why on stderr instead" \
  '1' "$(stderr_of maxturns.jsonl | grep -c 'carries no structured output')"
check "the two are different on stdout, which is the whole distinction" \
  '0' "$([ "$(rrun clean.jsonl)" = "$(rrun maxturns.jsonl)" ] && echo 1 || echo 0)"
check "neither is an error exit; the caller decides what the emptiness means" \
  '0 0' "$(rrun clean.jsonl > /dev/null 2>&1; printf '%s ' "$?"; \
    rrun maxturns.jsonl > /dev/null 2>&1; printf '%s' "$?")"

# An is_error result does not fall back to an earlier success either: the
# last result is the run's verdict, so an error one is not stepped over.
{
  cat "$WORK/normal.jsonl"
  printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Error: exceeded max turns"}'
} > "$WORK/errored_last.jsonl"
check "an is_error result does not fall back to an earlier success" \
  '' "$(rrun errored_last.jsonl)"
check "and the CLI's own diagnostic is not emitted as a review" \
  '0' "$(rrun errored_last.jsonl | grep -c 'exceeded max turns' || true)"

# THE SEAM, END TO END, AND IT IS THE SECOND LINE OF DEFENCE. In production
# the workflow gates on this program's output being non-blank
# (`grep -q '[^[:space:]]'`) and routes the empty case to its own "the review
# could not run" comment, so the errored transcript normally stops there.
# What this asserts is what happens if it does not: the two transcripts must
# still reach the pull request as different comments, and be told apart by a
# metric rather than by prose. The emptiness gate and this are independent,
# and the branch's worst defect was exactly a case where one layer silently
# did nothing.
(
  cd "$WORK"
  git init -q .
  git config user.email fixture@example.invalid
  git config user.name Fixture
  git config commit.gpgsign false
  printf 'package main\n' > real.go
  git add real.go
  git commit -qm base
) > /dev/null
printf 'modified\t1\treal.go\tpr-files/0001.patch\n' > "$WORK/manifest.tsv"

seam() { # seam <transcript> <body> -> runs both programs over one transcript
  ( cd "$WORK" && python3 "$SCRIPT" "$1" > "findings-$1.json" 2>/dev/null
    cd "$WORK" && python3 "$OUTPUT" --findings "findings-$1.json" \
      --manifest manifest.tsv --base HEAD --out "$2" --metrics "metrics-$1.env" \
      --head abc --lane B --coverage-read 1 --coverage-total 1 \
      --summary '1 file, +1/-1.' ) > /dev/null
}
: > "$WORK/metrics-clean.jsonl.env"
: > "$WORK/metrics-maxturns.jsonl.env"
seam clean.jsonl clean_body.md
seam maxturns.jsonl maxturns_body.md
check "a clean transcript becomes a clean verdict on the pull request" \
  '1' "$(grep -c '^✅ \*\*No blocking findings in the 1 of 1 file opened\.\*\* 1 file, +1/-1\.$' \
    "$WORK/clean_body.md")"
check "an errored transcript says nothing was adjudicated instead" \
  '1' "$(grep -c '^\*\*The reviewer produced no structured output\.\*\*' \
    "$WORK/maxturns_body.md")"
check "and the two are told apart by a metric, not only by prose" \
  '0 1' "$(sed -n 's/^REVIEW_NO_VERDICT=//p' "$WORK/metrics-clean.jsonl.env" | tr '\n' ' ' \
    | tr -d ' '; printf ' '; sed -n 's/^REVIEW_NO_VERDICT=//p' "$WORK/metrics-maxturns.jsonl.env")"

# ---------------------------------------------------------------------------
# Transcripts that must not be fatal
# ---------------------------------------------------------------------------

# A killed run leaves a half-written final line. It is skipped, and the last
# complete result still comes out.
{
  cat "$WORK/normal.jsonl"
  printf '%s' '{"type":"result","subtype":"success","is_error":false,"structu'
} > "$WORK/truncated.jsonl"
check "a truncated final line is skipped, not fatal" \
  '{"findings": [{"severity": "BLOCKER", "path": "pkg/real.go", "line": 3, "message": "Unvalidated input reaches the query builder — validate it."}]}' \
  "$(rrun truncated.jsonl)"

# A transcript with nothing adjudicable in it is empty output, which the
# workflow turns into its "review unavailable" comment.
printf '%s\n' '{"type":"system","subtype":"init"}' > "$WORK/bare.jsonl"
check "a transcript with nothing in it produces nothing" '' "$(rrun bare.jsonl)"

# A line that is valid JSON but not an object -- `_events` yields None for
# it rather than crashing on `.get`.
{
  printf '%s\n' '["not", "an", "object"]'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"findings":[]}}'
} > "$WORK/nonobject.jsonl"
check "a JSON line that is not an object is skipped, not fatal" \
  '{"findings": []}' "$(rrun nonobject.jsonl)"

# ---------------------------------------------------------------------------
# --events prints SHAPE only
# ---------------------------------------------------------------------------
#
# A tool result carries whole file contents, so a raw `tail` of this
# transcript into a public job log publishes source files out of the
# reviewer's Read calls. That is what this mode replaced.

EVENTS=$(erun normal.jsonl)
check "--events never prints tool result content" \
  '0' "$(printf '%s\n' "$EVENTS" | grep -c 'SECRET_FILE_BODY' || true)"
check "--events never prints assistant text, only its length" \
  '1' "$(printf '%s\n' "$EVENTS" | grep -c '^assistant text:7c tool_use:Read$')"
check "--events names the tool that was called" \
  '1' "$(printf '%s\n' "$EVENTS" | grep -c 'tool_use:Read')"
check "--events marks a result that carried an object" \
  '1' "$(printf '%s\n' "$EVENTS" | grep -c '^result/success ok structured$')"
# The job log has to show WHICH of the three empty outcomes happened, or a
# run that produced nothing is indistinguishable from a run that produced a
# clean verdict at exactly the moment somebody is trying to find out.
check "--events marks an errored result with its subtype" \
  '1' "$(erun maxturns.jsonl | grep -c '^result/error_max_turns is_error unstructured$')"
check "--events marks a successful result that carried no object" \
  '1' "$(erun prose_result.jsonl | grep -c '^result/success ok unstructured$')"
check "--events reports an unparsable line rather than skipping it" \
  '1' "$(erun truncated.jsonl | grep -c '<unparsable line>')"
# Bounded, whatever the transcript's size: the workflow used to pass
# `tail -40` and the bound moved into the program with the mode.
{
  for i in $(seq 1 60); do
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$i"
  done
} > "$WORK/long.jsonl"
check "--events is bounded to the newest 40 events" \
  '40' "$(erun long.jsonl | wc -l | tr -d ' ')"
check "and it is the newest that survive, not the oldest" \
  '1' "$(erun long.jsonl | tail -1 | grep -c '^assistant text:2c$')"

check "a bad argument list exits 2" \
  '2' "$(python3 "$SCRIPT" 2>/dev/null; echo $?)"
check "and names both forms on stderr" \
  '2' "$(python3 "$SCRIPT" 2>&1 >/dev/null | grep -c 'usage: review_text.py\|--events')"

if [ "$FAILED" -eq 0 ]; then
  echo "all review_text.py tests passed"
else
  echo "review_text.py tests FAILED" >&2
fi
exit "$FAILED"
