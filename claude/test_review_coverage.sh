#!/usr/bin/env bash
# cspell:ignore crun jsonl  -- test fixture / local constant names, not vocabulary
# Fixture tests for review_coverage.py. No framework: builds a manifest and a
# Claude Code stream-json transcript, runs the checker, and checks the count
# and the named misses.
#
# The central fixture is the failure this program exists to catch, reduced to
# its shape: a 33-file change including a 2,145-line source file no diff was
# rendered for, reviewed by a run that opened one markdown file and reported
# one finding from it. That run went green. Against this checker it must come
# back 1 of 5 with the unread source named.
#
# The second central fixture is the way the FIRST version of this checker was
# wrong: it counted `Read` tool calls and never looked at what they returned,
# so two reads that both came back "File does not exist" reported full
# coverage and the gate passed on exactly the condition it exists to catch.
# A call is a request; the tool_result says whether it opened anything.
#
# The other fixtures are the remaining ways a coverage check can be wrong in
# the reassuring direction: counting a patch read as covering a different
# file, crediting a row for a read of a different file with the same path
# tail, crediting a tool_result that carried nothing at all, counting a
# Grep or a Glob as a read, reporting full coverage when the transcript is
# missing entirely, reporting full coverage when NO read path stripped the
# workspace prefix and every row then matched by suffix, reporting a
# confident 0/N when the CLI's transcript envelope changed and no tool event
# could be found at all, reporting a binary-only change as unmeasured when
# none of its rows was openable and so none of them depended on the
# transcript, and demanding a read
# of a row that nothing could ever open -- a deleted file or a binary one --
# which would make every pull request containing one permanently uncovered.
#
# Usage:  ./test_review_coverage.sh     # from anywhere; exits non-zero on failure
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/review_coverage.py"
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

crun() { # crun <manifest> <transcript> -> the program's stdout
  python3 "$SCRIPT" "$WORK/$1" "$WORK/$2" --workspace "$W"
}
coverage_of() { printf '%s\n' "$1" | sed -n 's/^Coverage: \([^ ]*\).*/\1/p'; }
exempt_of() { printf '%s\n' "$1" | sed -n 's/^Exempt: \([0-9]*\) .*/\1/p'; }
missed_of() { printf '%s\n' "$1" | sed -n 's/^  ? //p' | paste -sd, -; }

# Absolute paths under the runner workspace, as the CLI records them.
W=/home/runner/work/repo/repo

# A Read is TWO events: the call, and the result that says whether it opened
# anything. Everything downstream of this distinction is the point of the
# program, so the fixtures emit both halves rather than the call alone.
call() { # call <id> <path>
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"Read","input":{"file_path":"%s"}}]}}\n' "$1" "$2"
}
result_ok() { # result_ok <id>
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","content":"1  contents"}]}}\n' "$1"
}
result_err() { # result_err <id> <message>
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","is_error":true,"content":"%s"}]}}\n' "$1" "$2"
}
result_bare() { # result_bare <id> -- neither flagged an error nor carrying content
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s"}]}}\n' "$1"
}
read_ok() { call "$1" "$2"; result_ok "$1"; }
read_err() { call "$1" "$2"; result_err "$1" "$3"; }

# The StructuredOutput call that carries the findings, which every run
# reaching the coverage step has made: the step is gated on review_text.py
# having recovered a structured output, and that exists only because the
# model called this tool. So a real transcript always holds at least one
# tool block, which is what makes 'no tool block at all' diagnostic of the
# envelope rather than of a run that used no tools.
structured_out() {
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"so1","name":"StructuredOutput","input":{"findings":[]}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"so1","content":"ok"}]}}'
}

# The failing shape. analyzer.rs is the "-" row: the largest file in the
# change, and the one nothing rendered a diff for.
printf '%s\n' \
  'modified	812	.claude/STATUS.md	pr-files/0002.patch' \
  'modified	2145	crates/analyzer/src/analyzer.rs	-' \
  'modified	424	crates/analyzer/src/report.rs	pr-files/0018.patch' \
  'modified	204	crates/analyzer/src/catalog.rs	pr-files/0016.patch' \
  'added	689	crates/analyzer/tests/parity/run_parity.py	pr-files/0032.patch' \
  > "$WORK/manifest.tsv"

# What that run's transcript would have held: the manifest, one patch, and
# nothing else.
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  read_ok t1 "$W/pr-files/manifest.tsv"
  read_ok t2 "$W/pr-files/0002.patch"
  printf '%s\n' '{"type":"result","is_error":false,"result":"**1 finding** — 0 blockers, 1 risk."}'
} > "$WORK/thin.jsonl"

echo "review_coverage.py"
LOG=$(crun manifest.tsv thin.jsonl)
check "the failing shape reports one row of five opened" \
  '1/5' "$(coverage_of "$LOG")"
check "the unread Rust is named first among the misses" \
  'crates/analyzer/src/analyzer.rs,crates/analyzer/src/report.rs,crates/analyzer/src/catalog.rs,crates/analyzer/tests/parity/run_parity.py' \
  "$(missed_of "$LOG")"

# THE REGRESSION TEST. Reads that came back is_error opened nothing. The
# first version of this checker counted the calls and reported 2/2 on exactly
# this transcript, and the job printed "every file in the manifest was
# opened" and exited 0. With the prompt now telling the model its reads are
# counted, the cheapest way to satisfy an unchecked counter is a Read per
# manifest row that need not succeed.
printf '%s\n' \
  'modified	10	src/present.rs	-' \
  'modified	10	src/vanished.rs	-' \
  > "$WORK/errs.tsv"
{
  read_err e1 "$W/src/present.rs" "This is a binary file and cannot be read"
  read_err e2 "$W/src/vanished.rs" "File does not exist."
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/errs.jsonl"
check "reads that came back is_error are not coverage" \
  '0/2' "$(coverage_of "$(crun errs.tsv errs.jsonl)")"

# One good read beside one failed one: the good one still counts, so the
# fix is not a blanket refusal to credit anything.
{
  read_ok g1 "$W/src/present.rs"
  read_err g2 "$W/src/vanished.rs" "File does not exist."
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/mixed.jsonl"
check "a successful read still counts beside a failed one" \
  '1/2' "$(coverage_of "$(crun errs.tsv mixed.jsonl)")"

# A call whose result never arrived -- a killed run, or a transcript whose
# envelope changed shape -- is not coverage either. It must fail toward "not
# reviewed", and the "with no result recorded" count makes it visible rather
# than silent.
{
  call u1 "$W/src/present.rs"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/unanswered.jsonl"
UNANSWERED=$(crun errs.tsv unanswered.jsonl)
check "a read with no result recorded is not coverage" \
  '0/2' "$(coverage_of "$UNANSWERED")"
check "the unanswered call is reported rather than swallowed" \
  '1' "$(printf '%s\n' "$UNANSWERED" | sed -n 's/^Read calls: .*, \([0-9]*\) with no result recorded.*/\1/p')"
check "and an unmatched call is annotated, not just printed" \
  '1' "$(printf '%s\n' "$UNANSWERED" | grep -c '^::warning::1 Read call')"

# A result with NO is_error field and no content is not a file opened. The
# error signal living in that one key is what the current transcript does,
# not a guarantee: `not is_error` credits anything a schema change moves
# elsewhere, so the default has to be "nothing was returned".
{
  call b1 "$W/src/present.rs"
  result_bare b1
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/bare.jsonl"
check "a result carrying neither an error flag nor content is not coverage" \
  '0/2' "$(coverage_of "$(crun errs.tsv bare.jsonl)")"

# A "-" row has no patch, so the working tree is the only place it can be
# covered from. Opening it there must count -- otherwise the check demands
# something impossible and every large PR is red for the wrong reason.
{
  cat "$WORK/thin.jsonl"
  read_ok t3 "$W/crates/analyzer/src/analyzer.rs"
} > "$WORK/tree.jsonl"
check "a '-' row opened in the working tree counts as covered" \
  '2/5' "$(coverage_of "$(crun manifest.tsv tree.jsonl)")"

# ROWS NOTHING CAN OPEN ARE EXEMPT, not uncovered. A deleted file is not in
# the working tree and a binary one cannot be read, so requiring either would
# make every pull request containing one permanently short of full coverage
# -- and the moment enforcement is set to fail, unmergeable.
printf '%s\n' \
  'removed	40	src/dropped.rs	-' \
  'modified	0	assets/logo.png	binary' \
  'modified	10	src/live.rs	pr-files/0001.patch' \
  > "$WORK/exempt.tsv"
{
  read_ok x1 "$W/pr-files/0001.patch"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/exempt.jsonl"
EXEMPT_LOG=$(crun exempt.tsv exempt.jsonl)
check "a deleted row with no patch and a binary row leave the denominator" \
  '1/1' "$(coverage_of "$EXEMPT_LOG")"
check "both exempt rows are counted and said out loud" \
  '2' "$(exempt_of "$EXEMPT_LOG")"

# A deletion WITH a patch is still reviewable -- the patch is the removed
# content -- so it stays in the denominator. The exemption is about what can
# be opened, not about the word "removed".
printf '%s\n' 'removed	40	src/dropped.rs	pr-files/0003.patch' > "$WORK/delpatch.tsv"
# `structured_out` rather than a bare `result` event: a transcript with no
# tool block at all is read as an envelope this program cannot parse, not
# as a run that opened nothing. See the envelope section below.
{
  structured_out
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/empty.jsonl"
check "a deleted row that has a patch is still required" \
  '0/1' "$(coverage_of "$(crun delpatch.tsv empty.jsonl)")"

# Several tool_use blocks in one assistant message is the normal shape when
# the model batches reads. Counting only the first would under-report and
# fail a review that did its job.
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reading\"},{\"type\":\"tool_use\",\"id\":\"b1\",\"name\":\"Read\",\"input\":{\"file_path\":\"$W/pr-files/0018.patch\"}},{\"type\":\"tool_use\",\"id\":\"b2\",\"name\":\"Read\",\"input\":{\"file_path\":\"$W/pr-files/0016.patch\"}}]}}"
  printf '%s\n' "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"b1\",\"content\":\"x\"},{\"type\":\"tool_result\",\"tool_use_id\":\"b2\",\"content\":\"y\"}]}}"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/batched.jsonl"
check "several reads in one message are all counted" \
  '2/5' "$(coverage_of "$(crun manifest.tsv batched.jsonl)")"

# Grep and Glob find paths; they do not open them. A review that greps the
# tree and reports from the hits has not read the change, and this is exactly
# how Lane A behaves, so it must not be mistaken for coverage.
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"q1\",\"name\":\"Grep\",\"input\":{\"pattern\":\"foo\",\"path\":\"$W/crates/analyzer/src/report.rs\"}}]}}"
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"hit"}]}}'
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"q2\",\"name\":\"Glob\",\"input\":{\"pattern\":\"**/*.rs\"}}]}}"
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q2","content":"a.rs"}]}}'
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/grepped.jsonl"
check "Grep and Glob are not reads" \
  '0/5' "$(coverage_of "$(crun manifest.tsv grepped.jsonl)")"

# A READ OF A DIFFERENT FILE WITH THE SAME PATH TAIL IS NOT COVERAGE. A
# path-boundary anchor does not catch this: `vendor/src/lib.rs` ends in
# `/src/lib.rs` on a separator and credited the row for the real `src/lib.rs`.
# `vendor/*` is in the default exclude_globs, so a vendored tree is absent
# from the manifest and present in the checkout -- which is what makes this
# the likely shape rather than a contrived one.
printf '%s\n' 'modified	10	src/lib.rs	-' > "$WORK/suffix.tsv"
{
  read_ok s1 "$W/vendor/src/lib.rs"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/suffix.jsonl"
check "a vendored copy of the same relative path is not coverage" \
  '0/1' "$(coverage_of "$(crun suffix.tsv suffix.jsonl)")"

# AN UNMEASURED REVIEW MUST NOT LOOK LIKE A REVIEW THAT OPENED NOTHING -- AND
# MUST NOT LOOK LIKE ONE THAT OPENED EVERYTHING. Exact matching assumes the
# transcript records paths under $GITHUB_WORKSPACE. When none of them does,
# the earlier shape left every read in the suffix set, so EVERY row matched
# something: the program printed total coverage, wrote COVERAGE_UNCOVERED=0,
# and the gate announced every file opened and exited 0 even under `fail`.
# The previous version of this fixture asserted that the warning string
# appeared and never looked at the number -- which is exactly how that
# shipped, so the assertions here are the numbers.
printf '%s\n' \
  'modified	10	src/lib.rs	-' \
  'modified	10	cmd/app/main.go	-' \
  > "$WORK/offworkspace.tsv"
{
  read_ok w1 "/elsewhere/vendor/crate/src/lib.rs"
  read_ok w2 "/elsewhere/third_party/cmd/app/main.go"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/offworkspace.jsonl"
: > "$WORK/off_env.txt"
OFF_LOG=$(python3 "$SCRIPT" "$WORK/offworkspace.tsv" "$WORK/offworkspace.jsonl" \
  --workspace "$W" --github-env "$WORK/off_env.txt" \
  --missed-file "$WORK/off_missed.txt")
check "no read path under the workspace reports unmeasured, not 2/2" \
  'unmeasured' "$(coverage_of "$OFF_LOG")"
check "and the annotation still says so" \
  '1' "$(printf '%s\n' "$OFF_LOG" | grep -c '::warning::no read path lies under')"
check "all four counts are the token rather than numbers" \
  'COVERAGE_TOTAL=unmeasured COVERAGE_READ=unmeasured COVERAGE_UNCOVERED=unmeasured COVERAGE_EXEMPT=unmeasured' \
  "$(tr '\n' ' ' < "$WORK/off_env.txt" | sed 's/ $//')"
check "COVERAGE_UNCOVERED is not the 0 the gate passes on" \
  '0' "$(grep -c '^COVERAGE_UNCOVERED=0$' "$WORK/off_env.txt")"
check "and no file is named unopened on the strength of nothing" \
  '0' "$([ -s "$WORK/off_missed.txt" ] && echo 1 || echo 0)"

# A VENDORED COPY OUTSIDE THE WORKSPACE CREDITS NOTHING even when other reads
# did strip the prefix. One real read keeps the run measured, so the token
# above does not cover this case and the suffix set could otherwise retire a
# row the reviewer never opened.
{
  read_ok v1 "$W/src/lib.rs"
  read_ok v2 "/elsewhere/third_party/cmd/app/main.go"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/vendored.jsonl"
check "an absolute read under another root is not coverage" \
  '1/2' "$(coverage_of "$(crun offworkspace.tsv vendored.jsonl)")"

# The same defect with a bare manifest path, which is where it bites hardest:
# a repository-root `main.go` was credited by any `*/main.go` in the tree.
printf '%s\n' 'modified	10	main.go	pr-files/0001.patch' > "$WORK/tail.tsv"
{
  read_ok n1 "$W/cmd/foo/main.go"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/tail.jsonl"
check "a deeper file ending in the manifest path is not coverage" \
  '0/1' "$(coverage_of "$(crun tail.tsv tail.jsonl)")"

# The row's own file still counts, exactly.
{
  read_ok n2 "$W/main.go"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/tailok.jsonl"
check "the row's own path counts" \
  '1/1' "$(coverage_of "$(crun tail.tsv tailok.jsonl)")"

# A read recorded OUTSIDE the workspace has no prefix to strip, so suffix
# matching is still the only thing available for it -- which is how a
# repo-relative path in the transcript keeps counting.
{
  read_ok n3 "main.go"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/outside.jsonl"
check "a read outside the workspace still matches by suffix" \
  '1/1' "$(coverage_of "$(crun tail.tsv outside.jsonl)")"

# filter_diff.py C-escapes the manifest's path column so one path cannot
# forge a TSV row, and git permits a tab in a filename. Compared raw, such a
# path could never match the transcript's real path and would be reported
# unread on every run, for ever.
printf 'modified\t10\tsrc/odd\\tname.rs\t-\n' > "$WORK/escaped.tsv"
{
  # JSON-escaped in the transcript, as the CLI writes it; json.loads turns
  # it back into the real tab the manifest escaped as "\t".
  read_ok c1 "$W/src/odd\\tname.rs"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/escaped.jsonl"
check "an escaped manifest path matches the real path in the transcript" \
  '1/1' "$(coverage_of "$(crun escaped.tsv escaped.jsonl)")"

# A missing transcript is zero reads, never full coverage. Failing open here
# would reinstate the exact defect: a run whose output we cannot inspect
# passing as though it had been inspected.
check "a missing transcript reports nothing covered" \
  '0/5' "$(coverage_of "$(python3 "$SCRIPT" "$WORK/manifest.tsv" \
    "$WORK/absent.jsonl" --workspace "$W")")"

# A truncated final line is what a killed or timed-out run leaves behind. The
# reads before it still happened and must still count.
{
  read_ok k1 "$W/pr-files/0018.patch"
  printf '%s' '{"type":"result","is_err'
} > "$WORK/truncated.jsonl"
check "a truncated transcript still counts the reads it recorded" \
  '1/5' "$(coverage_of "$(crun manifest.tsv truncated.jsonl)")"

# The workflow consumes these four names; renaming one silently disables the
# gate, which is the failure mode this whole program exists to prevent.
python3 "$SCRIPT" "$WORK/exempt.tsv" "$WORK/exempt.jsonl" --workspace "$W" \
  --github-env "$WORK/env.txt" > /dev/null
check "COVERAGE_TOTAL counts only the openable rows" \
  'COVERAGE_TOTAL=1' "$(grep '^COVERAGE_TOTAL=' "$WORK/env.txt")"
check "COVERAGE_READ reaches the environment file" \
  'COVERAGE_READ=1' "$(grep '^COVERAGE_READ=' "$WORK/env.txt")"
check "COVERAGE_UNCOVERED reaches the environment file" \
  'COVERAGE_UNCOVERED=0' "$(grep '^COVERAGE_UNCOVERED=' "$WORK/env.txt")"
check "COVERAGE_EXEMPT reaches the environment file" \
  'COVERAGE_EXEMPT=2' "$(grep '^COVERAGE_EXEMPT=' "$WORK/env.txt")"

# THE PATH LIST MUST NOT REACH THE ENVIRONMENT FILE. An earlier version of
# this program wrote COVERAGE_MISSED there, having first unescaped the
# C-quoting filter_diff.py applies -- so a pull request adding a file whose
# name contains a newline could append arbitrary variables to the job
# environment. The paths now go to --missed-file and the environment file
# carries counts only.
check "no path list reaches the environment file" \
  '0' "$(grep -c '^COVERAGE_MISSED=' "$WORK/env.txt")"
check "the environment file carries nothing but KEY=number lines" \
  '0' "$(grep -cv '^COVERAGE_[A-Z]*=[0-9]*$' "$WORK/env.txt")"

# A manifest path containing a newline, spelled the way filter_diff.py
# spells it. Unescaped into a line-oriented file it becomes two lines, the
# second of which is an assignment.
printf 'modified\t2\tsrc/a.go\tpr-files/0001.patch\n' > "$WORK/inject.tsv"
printf 'modified\t2\tevil\\nSECRET=leaked\tpr-files/0002.patch\n' >> "$WORK/inject.tsv"
: > "$WORK/inject_env.txt"
python3 "$SCRIPT" "$WORK/inject.tsv" "$WORK/absent.jsonl" --workspace "$W" \
  --github-env "$WORK/inject_env.txt" \
  --missed-file "$WORK/inject_missed.txt" > /dev/null
check "a newline in a path cannot reach the environment file at all" \
  '0' "$(grep -c 'SECRET' "$WORK/inject_env.txt")"
check "a newline in a path stays on one line of the missed file" \
  '2' "$(wc -l < "$WORK/inject_missed.txt" | tr -d ' ')"
check "the newline is re-escaped rather than written raw" \
  '1' "$(grep -c 'evil\\nSECRET=leaked' "$WORK/inject_missed.txt")"

# ---------------------------------------------------------------------------
# A path the workflow REVERTED to base content cannot be opened either
# ---------------------------------------------------------------------------
#
# The restore step runs `rm -rf` and `git checkout $MERGE_BASE --` over
# `.claude CLAUDE.md .ripgreprc .gitmodules .husky` AFTER the manifest is
# written. A row under one of those whose patch column is `-` or `omitted`
# sends the reviewer to a working-tree file that now holds the base's content,
# or to nothing at all where the pull request added it: the read cannot
# succeed, the row counts unopened, and under `fail` the author has no way to
# clear it. A row with a patch is unaffected -- the patch is what it is told
# to read and the patch is intact.
printf '%s\n' \
  'modified	30	.claude/CLAUDE.md	-' \
  'added	12	.ripgreprc	omitted' \
  'modified	20	.claude/agents/x.md	pr-files/0003.patch' \
  'modified	40	src/a.go	-' \
  > "$WORK/restored.tsv"
{
  read_ok r1 "$W/pr-files/0003.patch"
  printf '%s\n' '{"type":"result","is_error":false,"result":"x"}'
} > "$WORK/restored.jsonl"

# Without the flag, all four rows are demanded. This is the shape that made a
# row permanently uncoverable, kept as the control.
check "unflagged, the reverted rows are demanded like any other" \
  '1/4' "$(coverage_of "$(crun restored.tsv restored.jsonl)")"

RESTORED_LOG=$(python3 "$SCRIPT" "$WORK/restored.tsv" "$WORK/restored.jsonl" \
  --workspace "$W" --restored '.claude CLAUDE.md .ripgreprc .gitmodules .husky')
check "a patchless row under a restored path leaves the denominator" \
  '1/2' "$(coverage_of "$RESTORED_LOG")"
check "both reverted rows are counted exempt" '2' "$(exempt_of "$RESTORED_LOG")"
check "and each names the exemption rather than a severity" \
  '2' "$(printf '%s\n' "$RESTORED_LOG" | grep -c '\[RESTORED\]$')"
check "a reverted row with a patch stays in the denominator" \
  '0' "$(printf '%s\n' "$RESTORED_LOG" | grep -c '^  = \.claude/agents/x\.md' || true)"
check "a row outside the restored set is still demanded" \
  'src/a.go' "$(missed_of "$RESTORED_LOG")"

# Segment-wise, or `.husky-local/` would ride in on `.husky`.
printf 'modified\t5\t.husky-local/y.md\t-\n' > "$WORK/near.tsv"
check "a path that merely starts with a restored name is not exempt" \
  '0/1' "$(coverage_of "$(python3 "$SCRIPT" "$WORK/near.tsv" \
    "$WORK/restored.jsonl" --workspace "$W" --restored .husky)")"

# The reason code is what a coverage status is allowed to say. A severity
# is not, and the model has no vocabulary for one.
check "an exempt row names why it could not be opened" \
  '2' "$(python3 "$SCRIPT" "$WORK/exempt.tsv" "$WORK/exempt.jsonl" --workspace "$W" \
    | grep -c -E '^  = .*\[(BINARY|DELETED|NOPATCH)\]$')"

# ---------------------------------------------------------------------------
# AN UNREADABLE TRANSCRIPT ENVELOPE IS UNMEASURED, NOT ZERO
# ---------------------------------------------------------------------------
#
# The stream-json envelope is an undocumented interface. The CLI version is
# pinned and the installed one is checked against the pin, but a version that
# renamed `tool_use` or `tool_result` would leave the walk finding nothing:
# no read paths at all, so the off-workspace token above never fires either,
# and the program reported a MEASURED 0/N. On 170 repositories at a floating
# tag that is a comment on every pull request asserting nobody opened
# anything -- a confident zero from a broken instrument, which is the same
# class of failure as the thin review this program exists to catch.
#
# The discriminator is whether the walk found a tool block AT ALL, of any
# name. One proves the vocabulary is still the one this program reads, after
# which zero Read calls really is zero. None proves nothing.
renamed() { # renamed <id> <path> -- a read in an envelope this program cannot read
  printf '{"type":"assistant","message":{"content":[{"type":"tool_invoke","id":"%s","name":"Read","input":{"file_path":"%s"}}]}}\n' "$1" "$2"
  printf '{"type":"user","message":{"content":[{"type":"tool_output","tool_use_id":"%s","content":"1  contents"}]}}\n' "$1"
}
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  renamed y1 "$W/pr-files/manifest.tsv"
  renamed y2 "$W/crates/analyzer/src/analyzer.rs"
  renamed y3 "$W/crates/analyzer/src/report.rs"
  printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"findings":[]}}'
} > "$WORK/renamed.jsonl"
: > "$WORK/renamed_env.txt"
RENAMED_LOG=$(python3 "$SCRIPT" "$WORK/manifest.tsv" "$WORK/renamed.jsonl" \
  --workspace "$W" --github-env "$WORK/renamed_env.txt" \
  --missed-file "$WORK/renamed_missed.txt")
check "a renamed transcript envelope reports unmeasured, not 0/5" \
  'unmeasured' "$(coverage_of "$RENAMED_LOG")"
check "and the annotation names the envelope as what could not be read" \
  '1' "$(printf '%s\n' "$RENAMED_LOG" | grep -c '::warning::no tool_use or tool_result block')"
check "all four counts are the token rather than numbers" \
  'COVERAGE_TOTAL=unmeasured COVERAGE_READ=unmeasured COVERAGE_UNCOVERED=unmeasured COVERAGE_EXEMPT=unmeasured' \
  "$(tr '\n' ' ' < "$WORK/renamed_env.txt" | sed 's/ $//')"
check "COVERAGE_UNCOVERED is not the 0 the gate passes on" \
  '0' "$(grep -c '^COVERAGE_UNCOVERED=0$' "$WORK/renamed_env.txt")"
check "and no file is named unopened on the strength of nothing" \
  '0' "$([ -s "$WORK/renamed_missed.txt" ] && echo 1 || echo 0)"

# THE TWO UNMEASURED CAUSES MUST NOT COLLAPSE INTO EACH OTHER. They are
# diagnosed differently -- one is a wrong --workspace prefix, the other is a
# CLI that moved under the pin -- so the report has to say which, or whoever
# reads the job log is sent to the wrong place.
check "the off-workspace case is not reported as an unreadable envelope" \
  '0' "$(printf '%s\n' "$OFF_LOG" | grep -c 'no tool_use or tool_result block')"
check "and the unreadable envelope is not reported as a workspace mismatch" \
  '0' "$(printf '%s\n' "$RENAMED_LOG" | grep -c '::warning::no read path lies under')"

# A LEGIBLE TRANSCRIPT THAT OPENED NOTHING IS A MEASURED ZERO. The third
# case, handled deliberately rather than by accident: the envelope is the one
# this program reads, the model simply called no Read, and 0/5 is then a true
# statement about the run rather than a statement about the instrument.
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  structured_out
  printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"findings":[]}}'
} > "$WORK/noreads.jsonl"
check "a legible transcript carrying no Read is a measured zero" \
  '0/5' "$(coverage_of "$(crun manifest.tsv noreads.jsonl)")"

# A Grep-only run is the same thing with a different tool, and it is the
# shape the earlier fixture already covers -- kept here as the proof that the
# new token did not swallow it, because a review that grepped and reported
# from the hits genuinely opened nothing and must still say 0/5.
check "a Grep-only run is still a measured zero, not unmeasured" \
  '0/5' "$(coverage_of "$(crun manifest.tsv grepped.jsonl)")"

# ---------------------------------------------------------------------------
# A MANIFEST WITH NOTHING TO OPEN IS NOT UNMEASURED
# ---------------------------------------------------------------------------
#
# THE DEFECT. Both unmeasured causes replaced all four counts with the token,
# including on a pull request where no row was openable in the first place --
# a binary-only change. Nothing about those rows came from the transcript, so
# `0 of 0 openable` was true however broken the stream was; the token made
# the workflow read COVERAGE_UNCOVERED as a non-pass, turned a previously
# green check red, and sent whoever read it to the CLI version pin over a
# change with no file to read. Measured before the fix, on the two rows
# below: `COVERAGE_UNCOVERED=unmeasured`.
#
# This is also the ONLY case where withholding changes the gate's verdict. A
# degraded run can credit no row, so wherever a row is openable the count it
# withholds is a failing one either way -- which is why the control below
# still fires on the five-row manifest, and why this escape cannot be used to
# pass a thin review.
printf '%s\n' \
  'modified	0	assets/logo.png	binary' \
  'removed	40	src/dropped.rs	-' \
  > "$WORK/allexempt.tsv"
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"findings":[]}}'
} > "$WORK/noblocks.jsonl"
: > "$WORK/allexempt_env.txt"
ALLEXEMPT_LOG=$(python3 "$SCRIPT" "$WORK/allexempt.tsv" "$WORK/noblocks.jsonl" \
  --workspace "$W" --github-env "$WORK/allexempt_env.txt")
check "no openable row means real counts, not the token" \
  'COVERAGE_TOTAL=0 COVERAGE_READ=0 COVERAGE_UNCOVERED=0 COVERAGE_EXEMPT=2' \
  "$(tr '\n' ' ' < "$WORK/allexempt_env.txt" | sed 's/ $//')"
check "and the coverage line says 0/0 rather than unmeasured" \
  '0/0' "$(coverage_of "$ALLEXEMPT_LOG")"

# THE DIAGNOSIS IS NOT DROPPED WITH THE TOKEN. An envelope this program
# cannot read is still a defect worth a line in the job log, whatever the
# manifest happened to contain -- it just no longer fails the change.
check "the envelope warning is still raised" \
  '1' "$(printf '%s\n' "$ALLEXEMPT_LOG" | grep -c '::warning::no tool_use or tool_result block')"
check "and it does not claim counts that were not withheld" \
  '0' "$(printf '%s\n' "$ALLEXEMPT_LOG" | grep -c 'Coverage is reported as')"

# The same escape for the other cause: reads that all landed under another
# root, against a manifest with nothing to open.
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  structured_out
  read_ok z1 /other/root/src/live.rs
  printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"findings":[]}}'
} > "$WORK/allexempt_off.jsonl"
check "the off-workspace cause is escaped the same way" \
  '0/0' "$(coverage_of "$(crun allexempt.tsv allexempt_off.jsonl)")"

# THE BOUNDARY. One openable row and the token comes straight back: the
# escape is "nothing depended on the transcript", not "the transcript may be
# ignored".
check "one openable row and the unreadable envelope is unmeasured again" \
  'unmeasured' "$(coverage_of "$(crun manifest.tsv noblocks.jsonl)")"

if [ "$FAILED" -eq 0 ]; then
  echo "all review_coverage.py tests passed"
else
  echo "review_coverage.py tests FAILED" >&2
fi
exit "$FAILED"
