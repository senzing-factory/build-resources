#!/usr/bin/env bash
# cspell:ignore jsonl rrun erun trun tstderr  -- test fixture / local constant names
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

printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"findings":[],"notes":["the only changed line is a version pin and it resolves"]}}' \
  > "$WORK/clean.jsonl"
printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Error: exceeded max turns"}' \
  > "$WORK/maxturns.jsonl"

check "a clean review is an empty findings array, not an empty stream" \
  '{"findings": [], "notes": ["the only changed line is a version pin and it resolves"]}' "$(rrun clean.jsonl)"
# THE EVIDENCE IS PART OF THE OBJECT, so this program carries it across the
# seam untouched. It validates nothing and renders nothing -- `clean_items`
# in review_output.py is the only thing that reads a note -- but if the key
# were dropped here the comment would withhold the tick from every correct
# clean verdict in the fleet and nothing would say why.
check "and the notes come across with it, whole" \
  '1' "$(rrun clean.jsonl | grep -c '"notes": \["the only changed line is a version pin and it resolves"\]')"
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
# AND IT IS CLEAN BECAUSE OF WHAT THE TRANSCRIPT CARRIED. The tick is
# withheld from a run that recorded nothing, so this one assertion is the
# end-to-end proof that the evidence travels in the structured output: the
# CLI validated it, this program passed it through, and the adjudicator
# published it. Nothing on disk beside the transcript was involved.
check "and the evidence it carried is published beneath it" \
  '1' "$(grep -c '^the only changed line is a version pin and it resolves$' "$WORK/clean_body.md")"
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

# ---------------------------------------------------------------------------
# --telemetry prints OCCUPANCY, and nothing a file or a finding could reach
# ---------------------------------------------------------------------------
#
# The reviewer's own output cannot say how close the run came to its context
# window, and that is what decides coverage: two runs over identical rows,
# patches, prompt and model scored 48 of 48 and 24 of 48, the second having
# compacted three times and finished on a terminal reason instead of a
# verdict. None of that survived the run -- the transcript is a $RUNNER_TEMP
# file nothing uploads.
#
# These fixtures assert the three properties that make the mode safe to put
# in a PUBLIC job summary: it reports the last result even when that result
# is an error, it reports what it can when there is no result at all, and
# every string it prints is reduced to [A-Za-z0-9._:/-] so a transcript
# cannot inject markdown into the page it is written to.

trun() { python3 "$SCRIPT" --telemetry "$WORK/$1" 2>/dev/null; }
tstderr_of() { { python3 "$SCRIPT" --telemetry "$WORK/$1" >/dev/null; } 2>&1; }

# A complete run. Three assistant turns whose occupancies are 42,010 /
# 60,105 / 102, so the peak is NEITHER the first nor the last turn and is
# only 60,105 if all three usage components are summed: input_tokens alone
# gives 5, and omitting cache_creation_input_tokens gives 60,005.
{
  printf '%s\n' '{"type":"system","subtype":"init","model":"claude-opus-5"}'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000},"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/w/pkg/real.go"}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"package main // SECRET_FILE_BODY"}]}}'
  printf '%s\n' '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":150000}}'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":60000,"cache_creation_input_tokens":100},"content":[{"type":"text","text":"**BLOCKER** `pkg/real.go:3` unvalidated input."}]}}'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":1}}}'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":33,"stop_reason":"end_turn","total_cost_usd":1.23456,"modelUsage":{"claude-opus-5":{"contextWindow":1000000,"maxOutputTokens":64000}},"structured_output":{"findings":[]}}'
} > "$WORK/telemetry.jsonl"

TELEMETRY=$(trun telemetry.jsonl)
check "--telemetry names the model the run actually used" \
  '1' "$(printf '%s\n' "$TELEMETRY" | grep -c '^model: claude-opus-5$')"
check "and the model is the FIRST line, so the summary leads with it" \
  'model: claude-opus-5' "$(printf '%s\n' "$TELEMETRY" | head -1)"
check "peak occupancy is the MAX turn and sums all three usage components" \
  '1' "$(printf '%s\n' "$TELEMETRY" | grep -c '^peak_context_tokens: 60105$')"
check "the window and output cap come from the result's modelUsage" \
  '1' "$(printf '%s\n' "$TELEMETRY" | grep -c '^window: claude-opus-5 context=1000000 max_output=64000$')"
check "--telemetry reports the turn count" \
  '1' "$(printf '%s\n' "$TELEMETRY" | grep -c '^num_turns: 33$')"
check "--telemetry reports the stop reason" \
  '1' "$(printf '%s\n' "$TELEMETRY" | grep -c '^stop_reason: end_turn$')"
check "--telemetry reports the cost to four places" \
  '1' "$(printf '%s\n' "$TELEMETRY" | grep -c '^total_cost_usd: 1\.2346$')"
check "--telemetry counts compaction boundaries" \
  '1' "$(printf '%s\n' "$TELEMETRY" | grep -c '^compact_boundaries: 1$')"
# THE WHOLE REASON THIS IS SAFE TO PUBLISH. The transcript it just read
# carries a file body out of a Read result and a finding out of an assistant
# text block; a raw tail of it into a public job log published both.
check "--telemetry never prints tool result content" \
  '0' "$(printf '%s\n' "$TELEMETRY" | grep -c 'SECRET_FILE_BODY' || true)"
check "--telemetry never prints a finding" \
  '0' "$(printf '%s\n' "$TELEMETRY" | grep -c 'BLOCKER\|real.go' || true)"
check "--telemetry prints only the fields it declares" \
  '8' "$(printf '%s\n' "$TELEMETRY" | wc -l | tr -d ' ')"

# AN ERRORED RESULT IS THE MOST VALUABLE TELEMETRY IN THE FILE, and this is
# the deliberate difference from the findings mode above, which discards it.
# The run that ran out of window is the one whose turn count and terminal
# reason someone needs; it is also the run with no verdict to read instead.
{
  printf '%s\n' '{"type":"system","subtype":"init","model":"claude-opus-5"}'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":60000,"cache_creation_input_tokens":100}}}'
  printf '%s\n' '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":150000}}'
  printf '%s\n' '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":150000}}'
  printf '%s\n' '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":150000}}'
  printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":32,"stop_reason":"max_turns","terminal_reason":"rapid_refill_breaker","total_cost_usd":4.5}'
} > "$WORK/constrained.jsonl"
CONSTRAINED=$(trun constrained.jsonl)
check "an errored result still yields its terminal reason" \
  '1' "$(printf '%s\n' "$CONSTRAINED" | grep -c '^terminal_reason: rapid_refill_breaker$')"
check "and its turn count, which the findings mode throws away" \
  '1' "$(printf '%s\n' "$CONSTRAINED" | grep -c '^num_turns: 32$')"
check "three compactions are counted, not collapsed to one" \
  '1' "$(printf '%s\n' "$CONSTRAINED" | grep -c '^compact_boundaries: 3$')"
check "the same transcript still adjudicates nothing, which is the point" \
  '' "$(rrun constrained.jsonl)"

# A killed run: no result event at all. Everything that does not come from
# the result is still measurable, and that is the case the mode exists for.
{
  printf '%s\n' '{"type":"system","subtype":"init","model":"claude-sonnet-4-6"}'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000}}}'
} > "$WORK/noresult_telemetry.jsonl"
NORESULT=$(trun noresult_telemetry.jsonl)
check "with no result event the occupancy is still reported" \
  '1' "$(printf '%s\n' "$NORESULT" | grep -c '^peak_context_tokens: 42010$')"
check "and the fields that only a result can answer read as absent" \
  '3' "$(printf '%s\n' "$NORESULT" | grep -c '^num_turns: -$\|^stop_reason: -$\|^total_cost_usd: -$')"
check "no modelUsage means no window line, rather than a guessed one" \
  '0' "$(printf '%s\n' "$NORESULT" | grep -c '^window: ' || true)"

# `-` and `0` are different answers and must not collapse. A run that died
# before its first assistant message measured nothing; a turn whose usage
# carried nothing countable measured zero.
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-opus-5"}' \
  > "$WORK/no_usage.jsonl"
check "no assistant turn at all reports an absent occupancy, not zero" \
  '1' "$(trun no_usage.jsonl | grep -c '^peak_context_tokens: -$')"
# An assistant turn carrying no `usage` block at all is the same answer, and
# it is a DIFFERENT code path from having no assistant turn: this one reaches
# the per-turn reader and has to decline there.
{
  printf '%s\n' '{"type":"system","subtype":"init","model":"claude-opus-5"}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
} > "$WORK/turn_no_usage.jsonl"
check "an assistant turn with no usage block is absent, not zero either" \
  '1' "$(trun turn_no_usage.jsonl | grep -c '^peak_context_tokens: -$')"
{
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":"many","cache_read_input_tokens":null}}}'
} > "$WORK/bad_usage.jsonl"
check "a turn whose usage is unreadable reports a measured zero" \
  '1' "$(trun bad_usage.jsonl | grep -c '^peak_context_tokens: 0$')"
# A boolean is an int in Python. Printed as 1 it would read as one turn.
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":true,"total_cost_usd":true}' \
  > "$WORK/bool_result.jsonl"
check "a boolean turn count is absent, not 1" \
  '1' "$(trun bool_result.jsonl | grep -c '^num_turns: -$')"
check "a boolean cost is absent, not 1.0000" \
  '1' "$(trun bool_result.jsonl | grep -c '^total_cost_usd: -$')"

# THE SUMMARY IS RENDERED AS MARKDOWN. A model id arrives from the CLI, but
# the mode must not be the thing that trusts it: a newline would break the
# field into two and a `#` would open a heading in the published page.
printf '%s\n' '{"type":"system","subtype":"init","model":"evil\n### Injected"}' \
  > "$WORK/injection.jsonl"
INJECTED=$(trun injection.jsonl)
check "a newline in a model id cannot split the field" \
  '7' "$(printf '%s\n' "$INJECTED" | wc -l | tr -d ' ')"
check "and every disallowed character is replaced, not dropped" \
  '1' "$(printf '%s\n' "$INJECTED" | grep -c '^model: evil?????Injected$')"
check "so no heading reaches the job summary" \
  '0' "$(printf '%s\n' "$INJECTED" | grep -c '^###' || true)"

# A `system` event is not automatically a compaction. Counting by type
# rather than subtype would turn every init into one.
printf '%s\n' '{"type":"system","subtype":"model_refresh"}' > "$WORK/other_system.jsonl"
check "a system event of another subtype is not a compaction" \
  '1' "$(trun other_system.jsonl | grep -c '^compact_boundaries: 0$')"

# Two models in one run -- a fallback, or a model change mid-session. Both
# windows are reported and neither is reconciled against the init model,
# because choosing between them would be a guess printed as a measurement.
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"modelUsage":{"claude-sonnet-4-6":{"contextWindow":200000,"maxOutputTokens":8192},"claude-opus-5":{"contextWindow":1000000,"maxOutputTokens":64000}}}' \
  > "$WORK/two_models.jsonl"
check "every model the run billed gets its own window line" \
  '2' "$(trun two_models.jsonl | grep -c '^window: ')"
check "and they are sorted, so the same run summarises the same way twice" \
  'window: claude-opus-5 context=1000000 max_output=64000' \
  "$(trun two_models.jsonl | grep '^window: ' | head -1)"

# Same two non-fatal cases as the findings mode: this runs on the failure
# paths, so it must not be the step that fails the job.
{
  cat "$WORK/telemetry.jsonl"
  printf '%s' '{"type":"result","subtype":"success","is_error":false,"num_tu'
} > "$WORK/truncated_telemetry.jsonl"
check "a truncated final line is skipped, not fatal" \
  '1' "$(trun truncated_telemetry.jsonl | grep -c '^num_turns: 33$')"
check "a missing transcript prints nothing and exits 0" \
  ' 0' "$(python3 "$SCRIPT" --telemetry "$WORK/absent.jsonl" 2>/dev/null; printf ' %s' "$?")"
check "and says why on stderr, where it cannot reach the summary" \
  '1' "$(tstderr_of absent.jsonl | grep -c 'no transcript to summarise')"

check "a bad argument list exits 2" \
  '2' "$(python3 "$SCRIPT" 2>/dev/null; echo $?)"
check "and names all three forms on stderr" \
  '3' "$(python3 "$SCRIPT" 2>&1 >/dev/null | grep -c 'usage: review_text.py\|--events\|--telemetry')"

if [ "$FAILED" -eq 0 ]; then
  echo "all review_text.py tests passed"
else
  echo "review_text.py tests FAILED" >&2
fi
exit "$FAILED"
