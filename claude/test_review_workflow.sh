#!/usr/bin/env bash
# cspell:ignore inrun unrun  -- an awk local and a comment's own word, not vocabulary
# Fixture tests for the reviewer workflow's own guards.
#
# WHY THIS FILE EXISTS. On 2026-10-29 five pull requests were reviewed by a
# workflow pinned at `@330-skern` whose helper scripts came from `main`. The
# workflow FILE honoured the pin; the `build-resources` CHECKOUT that supplies
# every `claude/*.py`, `pr-prompt-v2.md` and `review-schema.json` did not,
# because `ref:` was an expression that evaluated to the empty string and
# `actions/checkout` then took the default branch. The step whose whole job
# was to catch that read an empty expected value as "running directly" and
# allowed it through -- it FAILED OPEN, and so the canary proved nothing
# about the code it was supposed to be exercising.
#
# Six fixture suites covered the helpers and not one covered the workflow, so
# there was nothing that could have failed. This is that something.
#
# HOW IT TESTS. The guard's `run:` body is EXTRACTED FROM THE WORKFLOW FILE
# and executed, rather than restated here. A copy of the logic would pass
# while the workflow drifted away from it, which is the same class of defect
# as the one above: a check that is not reading the artefact under test.
#
# Extraction is awk over the indentation, deliberately, rather than a YAML
# parser: this runs on a GitHub runner where the Python YAML module is not
# guaranteed, and a test that fails on a missing import tells you nothing
# about the workflow.
#
# Usage:  ./test_review_workflow.sh      # from anywhere; exits non-zero on failure
#         WORKFLOW_FILE=<path> ./test_review_workflow.sh
#         LINT_WORKFLOW_FILE=<path> ./test_review_workflow.sh
#
# The override exists so the guard can be run against an OLDER revision of
# the workflow to prove an assertion fails there before it passes here.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORKFLOW_FILE="${WORKFLOW_FILE:-$HERE/../.github/workflows/claude-pull-request-review.yaml}"
LINT_WORKFLOW_FILE="${LINT_WORKFLOW_FILE:-$HERE/../.github/workflows/lint-repo.yaml}"
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

# The `run:` body of one named step, with the block indentation stripped.
# Steps sit at six spaces, their keys at eight, and a block scalar's content
# at ten.
extract_step() { # extract_step <step name> -> the shell it runs
  awk -v want="      - name: $1" '
    $0 == want { instep = 1; next }
    instep && /^      - name: / { exit }
    instep && /^        run: \|/ { inrun = 1; next }
    inrun {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^          /) { exit }
      sub(/^          /, ""); print
    }
  ' "$WORKFLOW_FILE"
}

GUARD="$WORK/guard.sh"
extract_step "Verify build resources checkout" > "$GUARD"

check "the guard's shell was found in the workflow file" \
  '1' "$([ -s "$GUARD" ] && echo 1 || echo 0)"

# A checked-out build-resources, so "the checkout is fine" is a state the
# fixtures can actually be in. `git -C build-resources rev-parse HEAD` is the
# only thing the guard reads from disk.
#
# The helper files are created too, because the same step checks for them:
# without them these fixtures would fail on the file check and report a ref
# problem that is not there. The LIST IS READ OFF THE GUARD, not restated --
# a copy here would go stale the moment the guard gained a file, and the
# symptom (every case reporting a ref problem that is not there) looks
# nothing like a stale list. There was a prose count of them here too.
mk_checkout() { # mk_checkout <dir>
  mkdir -p "$1/build-resources/claude"
  # `while read`, not `for f in $(...)`: the list is a line per file and
  # word-splitting it is what SC2013 is about.
  awk '/^ *for f in claude\//,/; do$/' "$GUARD" \
    | grep -oE 'claude/[A-Za-z0-9._-]+' \
    | while IFS= read -r f; do
        : > "$1/build-resources/$f"
      done
  git -C "$1/build-resources" init -q
  git -C "$1/build-resources" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m c
}

# run_guard <case> <caller repo> <expected sha> <with checkout?> [workflow repo]
# Echoes what the guard wrote to GITHUB_ENV.
# An EXPECTED SHA of `MATCH` means "whatever this fixture's own checkout is
# at". Two separately created repositories only agree when their commits land
# in the same second, so comparing across them is a test that passes most of
# the time -- which is worse than one that fails.
run_guard() {
  local dir="$WORK/$1" expected="$3"
  mkdir -p "$dir"
  [ "$4" = "yes" ] && mk_checkout "$dir"
  if [ "$expected" = "MATCH" ]; then
    expected=$(git -C "$dir/build-resources" rev-parse HEAD)
  fi
  : > "$dir/github.env"
  ( cd "$dir" && \
    GITHUB_ENV="$dir/github.env" \
    EXPECTED_SHA="$expected" \
    CALLER_REPO="$2" \
    SELF_REPO=senzing-factory/build-resources \
    WORKFLOW_REPO="${5:-}" \
    bash "$GUARD" > "$dir/log.txt" 2>&1 ) || true
  cat "$dir/github.env"
}

outcome_of() { # outcome_of <guard output> -> the REVIEW_OUTCOME it set, or none
  printf '%s\n' "$1" | sed -n 's/^REVIEW_OUTCOME=//p' | tail -1
}

# ---------------------------------------------------------------------------
# THE CASE THAT HAPPENED. A caller pinned a ref in `uses:` and named none
# here, so the checkout took the default branch. Everything downstream looks
# healthy -- the files exist, the job goes green, the review posts -- and the
# code that ran is not the code that was pinned.
# ---------------------------------------------------------------------------
CALLED_NO_REF=$(run_guard called_no_ref "example-org/consumer" "" "yes")
check "a consumer whose self-pin did not resolve is not reviewed" \
  'error' "$(outcome_of "$CALLED_NO_REF")"

# The reason has to name the expression, because the next person to see this
# needs to know which value was empty rather than that something went wrong.
check "and the error names the expression that came back empty" \
  '1' "$(printf '%s\n' "$CALLED_NO_REF" | grep -c 'job\.workflow_sha')"

# FAILING CLOSED IS THE POINT. A green review built on unverified helpers is
# worse than no review, because a required check that passes is read as the
# code having been reviewed.
check "the review is not allowed to proceed on the default branch" \
  '0' "$(printf '%s\n' "$CALLED_NO_REF" | grep -c '^REVIEW_OUTCOME=reviewed')"

# ---------------------------------------------------------------------------
# The three states that must still be allowed through, so the guard is not
# simply refusing everything.
# ---------------------------------------------------------------------------

# Running directly in build-resources: there is no caller to name a ref, and
# the default branch is the right answer. This is the ONLY empty-ref state
# that is benign, and distinguishing it is why the test is on the repository
# name -- which cannot be empty -- rather than on the ref, which can.
DIRECT=$(run_guard direct "senzing-factory/build-resources" "" "yes")
check "running directly in build-resources is still allowed" \
  '' "$(outcome_of "$DIRECT")"

# A caller that did name its ref.
# The expected SHA has to BE the checkout's HEAD here, because the mismatch
# check below it is live: a pin that resolved and a checkout that honoured it
# are the same commit, and anything else is the hazard arriving by a second
# route.
PINNED=$(run_guard pinned "example-org/consumer" "MATCH" "yes")
check "a consumer whose pin resolved and matched is allowed" \
  '' "$(outcome_of "$PINNED")"

# THE SECOND ROUTE. A pin that resolved but a checkout at some other commit
# is still unverified code, and this is the check that was already there.
MISMATCH=$(run_guard mismatch "example-org/consumer" "0000000000000000000000000000000000000000" "yes")
check "a pin the checkout did not honour is an error" \
  'error' "$(outcome_of "$MISMATCH")"

# ---------------------------------------------------------------------------
# The SECOND witness the job context supplies for free: which repository the
# running workflow file came from. A fork of build-resources running its own
# copy resolves a commit that does not exist in senzing-factory's, so the
# checkout would silently fall back rather than fail on the SHA.
# ---------------------------------------------------------------------------
FOREIGN=$(run_guard foreign "example-org/consumer" "MATCH" "yes" "someone-else/build-resources")
check "a workflow file from another repository is refused" \
  'error' "$(outcome_of "$FOREIGN")"

# INERT WHEN ABSENT, which is the whole reason it is safe to depend on a
# property this actionlint does not yet know. GitHub Enterprise Server does
# not supply the job context's workflow-identity fields; an empty value must
# change nothing rather than refuse every run.
ABSENT_REPO=$(run_guard absent_repo "example-org/consumer" "MATCH" "yes" "")
check "and an absent value refuses nothing" \
  '' "$(outcome_of "$ABSENT_REPO")"

# ---------------------------------------------------------------------------
# A checkout that produced nothing. `continue-on-error: true` on the checkout
# means a clone failure arrives here as an empty HEAD rather than a red step,
# so this is where it has to become visible.
# ---------------------------------------------------------------------------
NO_CHECKOUT=$(run_guard no_checkout "example-org/consumer" "" "no")
check "a checkout that produced nothing is an error, not a review" \
  'error' "$(outcome_of "$NO_CHECKOUT")"

# ---------------------------------------------------------------------------
# The workflow and the helpers have to agree about where the ref comes from.
# The guard reading an input the checkout does not use would pass every
# assertion above while pinning nothing.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # a literal workflow expression under test
check "the checkout and the guard read the same expression" \
  '2' "$(grep -c '\${{ job.workflow_sha }}' "$WORKFLOW_FILE")"

# THE WRONG CONTEXT IS THE WHOLE DEFECT, so it gets its own assertion.
# `job_workflow_sha` is an OIDC claim and has never been a `github` context
# property; reaching for it there is what produced an empty ref, and the
# names are close enough that it will be reached for again.
# shellcheck disable=SC2016  # a literal workflow expression under test
check "nothing reads the self-pin off the github context" \
  '0' "$(grep -v '^[[:space:]]*#' "$WORKFLOW_FILE" \
    | grep -c 'github\.\(job_\)\?workflow_sha')"

# The expression that silently evaluated empty must not come back, in either
# the direct or the serialized-context form. Comment lines are excluded: the
# superseded form is deliberately recorded in a comment beside its
# replacement, because a reader who does not know it was tried will try it.
# THE INDIRECTION MUST NOT COME BACK. It is what made the pin decorative,
# and it looks more careful than the direct form rather than less.
# Comments are excluded: the superseded form is deliberately recorded beside
# its replacement, because a reader who does not know it was tried will try
# it again and reintroduce exactly this defect.
check "the serialized-context indirection is gone" \
  '0' "$(grep -v '^[[:space:]]*#' "$WORKFLOW_FILE" \
    | grep -c 'fromJSON(toJSON(github))')"

# ---------------------------------------------------------------------------
# WHICH EARLIER COMMENT IS THE BASELINE. The step's own shell, extracted and
# run against a stubbed `gh`.
# ---------------------------------------------------------------------------
#
# THE DEFECT THIS CLOSES. The lookup ended `sort -n | head -1` -- the LOWEST
# comment id -- which was right while the review was one comment edited in
# place: converging on a single id is what kept the thread to one review.
# Nothing is edited now. Every push appends, so `head -1` selected the FIRST
# review ever posted on the pull request and kept selecting it forever, and
# `previous_stats()` fed the regression detector a frozen baseline from the
# second push onward. That detector exists to catch "longer output, fewer
# findings", which is the under-reporting the 2026-10-29 work was opened to
# fix -- so it was pointed away from its own target.
#
# TWO SUB-CASES BECAME REACHABLE at the same time, because a skip, error or
# cancellation notice is now its OWN comment carrying the same marker rather
# than an edit of the review's. A lane=T cancellation has no `findings=` at
# all, so `previous_stats` returns -1 and the comparison is permanently dead
# on that pull request; a lane=E skip carries `findings=0`, so every later
# review compares against zero and the detector never fires. Both are
# selected by a lowest-id rule, because a notice is usually what a pull
# request gets first.
#
# WHAT WAS CHOSEN: newest id, and ONLY a comment whose marker carries a
# review lane. Comparing a review against a notice is meaningless in both
# directions, so notices are not eligible as a baseline at all -- see
# REVIEW_BASELINE_JQ in the workflow, which is read off the file below
# rather than restated here.
#
# jq IS A HARD REQUIREMENT of these fixtures, not an optional path. `gh
# api --jq` is what the step filters with, and a stub that approximated it
# would be testing the approximation.
check "jq is available to run the baseline fixtures" \
  'yes' "$(command -v jq > /dev/null 2>&1 && echo yes || echo no)"

BASELINE_STEP="$WORK/baseline.sh"
extract_step "Find this reviewer's previous review" > "$BASELINE_STEP"
check "the baseline lookup's shell was found in the workflow file" \
  '1' "$([ -s "$BASELINE_STEP" ] && echo 1 || echo 0)"

# READ OFF THE WORKFLOW, like the suite list below. A copy of the predicate
# here would keep passing while the workflow's own drifted.
BASELINE_JQ=$(sed -n "s/^      REVIEW_BASELINE_JQ: '\(.*\)'$/\1/p" "$WORKFLOW_FILE")
check "the baseline predicate was found in the workflow file" \
  '1' "$([ -n "$BASELINE_JQ" ] && echo 1 || echo 0)"

# THE STUB. `gh api graphql` answers with the identity; `gh api
# .../issues/<n>/comments` applies the real jq to the fixture array; `gh api
# .../issues/comments/<id>` returns that one comment's body.
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
filter=""
url=""
want_jq=0
for a in "$@"; do
  if [ "$want_jq" = 1 ]; then filter="$a"; want_jq=0; continue; fi
  case "$a" in
    --jq) want_jq=1 ;;
    graphql) printf '%s\n' "${FAKE_VIEWER_ID}"; exit 0 ;;
    repos/*) url="$a" ;;
  esac
done
case "$url" in
  */issues/comments/*)
    jq -r --arg id "${url##*/}" \
      '.[] | select(.id == ($id | tonumber)) | .body' "$FAKE_COMMENTS"
    ;;
  *)
    jq -r "$filter" "$FAKE_COMMENTS"
    ;;
esac
STUB
chmod +x "$WORK/gh"

# run_baseline <case> <comments json>
# Echoes the COMMENT_ID the step settled on, or the empty string.
run_baseline() {
  local dir="$WORK/bl_$1"
  mkdir -p "$dir"
  printf '%s\n' "$2" > "$dir/comments.json"
  : > "$dir/github.env"
  ( PATH="$WORK:$PATH" \
    RUNNER_TEMP="$dir" \
    GITHUB_ENV="$dir/github.env" \
    GITHUB_REPOSITORY=example-org/consumer \
    PR_NUMBER=7 \
    IS_FORK=false \
    FAKE_VIEWER_ID=4242 \
    FAKE_COMMENTS="$dir/comments.json" \
    REVIEW_BASELINE_JQ="$BASELINE_JQ" \
    bash "$BASELINE_STEP" > "$dir/log.txt" 2>&1 ) || true
  sed -n 's/^COMMENT_ID=//p' "$dir/github.env" | tail -1
}

cmt() { # cmt <id> <marker tail> -> one comment object
  printf '{"id":%s,"user":{"id":4242},"body":"## Claude Code Review\\n\\n<!-- claude-review v3 %s -->"}' \
    "$1" "$2"
}

# THE HEADLINE CASE. Three reviews, and the newest is the only one the
# detector has a question about. `head -1` answers 101 here forever.
THREE="[$(cmt 101 'lane=B findings=5 blockers=1 read=4/4 head=aaa'),
$(cmt 202 'lane=B findings=4 blockers=1 read=4/4 head=bbb'),
$(cmt 303 'lane=C findings=2 blockers=0 read=4/4 head=ccc')]"
check "the newest review is the baseline, not the first one ever posted" \
  '303' "$(run_baseline three "$THREE")"

# And the body that was fetched is that comment's, not another's -- the id
# alone would pass if `previous.md` were written from the wrong one.
check "and previous.md holds the newest review's body" \
  '1' "$(grep -c 'findings=2 blockers=0' "$WORK/bl_three/previous.md")"

# A CANCELLATION FIRST. lane=T carries no `findings=`, so selecting it makes
# `previous_stats` return -1 and the comparison is dead for the life of the
# pull request.
CANCELLED_FIRST="[$(cmt 50 'lane=T blockers=0 read=0/0 head=aaa'),
$(cmt 300 'lane=B findings=3 blockers=0 read=4/4 head=bbb')]"
check "a cancellation notice is not a baseline" \
  '300' "$(run_baseline cancelled "$CANCELLED_FIRST")"

# A SKIP FIRST. lane=E carries `findings=0`, which is the other way the
# comparison dies: every later review compares against zero.
SKIP_FIRST="[$(cmt 60 'lane=E findings=0 blockers=0 read=0/0 head=aaa'),
$(cmt 310 'lane=B findings=3 blockers=0 read=4/4 head=bbb')]"
check "a skip notice is not a baseline either" \
  '310' "$(run_baseline skip "$SKIP_FIRST")"

# THE NEWEST END OF THE THREAD NEEDS THE SAME RULE. Taking the highest id
# WITHOUT the lane test lands on the notice, which is the defect arriving
# from the other direction.
NOTICE_LAST="[$(cmt 100 'lane=B findings=6 blockers=2 read=4/4 head=aaa'),
$(cmt 300 'lane=C findings=3 blockers=0 read=4/4 head=bbb'),
$(cmt 400 'lane=X findings=0 blockers=0 read=0/0 head=ccc')]"
check "an error notice posted after the review is not the baseline" \
  '300' "$(run_baseline notice_last "$NOTICE_LAST")"

# NO REVIEW AT ALL is "no comparison available", which is what -1 means --
# and it has to be the ABSENCE of previous.md, not a notice standing in.
ONLY_NOTICES="[$(cmt 70 'lane=E findings=0 blockers=0 read=0/0 head=aaa'),
$(cmt 80 'lane=T blockers=0 read=0/0 head=bbb')]"
check "a thread of notices and no review yields no baseline" \
  '' "$(run_baseline only_notices "$ONLY_NOTICES")"
check "and writes no previous.md for previous_stats to read" \
  '0' "$([ -e "$WORK/bl_only_notices/previous.md" ] && echo 1 || echo 0)"

# A COMMENT FROM SOMEONE ELSE carrying the marker is not this reviewer's
# review. The identity half of the predicate, re-asserted here because the
# lane half is new and the two are easy to confuse when one is edited.
FOREIGN_AUTHOR='[{"id":500,"user":{"id":99},"body":"<!-- claude-review v3 lane=B findings=9 blockers=9 read=4/4 head=aaa -->"},
'"$(cmt 400 'lane=B findings=1 blockers=0 read=4/4 head=bbb')"']'
check "a marker quoted by another author is not a baseline" \
  '400' "$(run_baseline foreign_author "$FOREIGN_AUTHOR")"

# THE TWO PREDICATES ARE NOT INTERCHANGEABLE, and collapsing them would be
# the quiet regression. The baseline lookup takes the narrow one; the
# discussion fetch NEGATES the wide one, and it has to stay wide or the
# reviewer is fed its own skip and error notices as third-party context.
# shellcheck disable=SC2016  # a literal workflow expression under test
check "the baseline lookup reads the narrow predicate" \
  '1' "$(grep -c 'select(${REVIEW_BASELINE_JQ})' "$WORKFLOW_FILE")"
# shellcheck disable=SC2016  # a literal workflow expression under test
check "and the discussion fetch still negates the wide one" \
  '1' "$(grep -c 'select((${REVIEW_COMMENT_JQ}) | not)' "$WORKFLOW_FILE")"
# The lowest-id selection must not come back. It is one word away from the
# current form and it reads as the more conservative of the two.
check "the baseline is taken from the newest id, not the oldest" \
  '0' "$(grep -c 'sort -n | head -1' "$WORKFLOW_FILE")"

# ---------------------------------------------------------------------------
# THE ANCHOR LINE, RENDERED TWICE AND REQUIRED TO AGREE
# ---------------------------------------------------------------------------
#
# Mechanism 13's line has two renderers: `anchor()` in review_output.py for
# the review's own body, and `anchor_line` in the sourced helper for the
# skip, bot-skip and error notices. The Python refuses to build the LINKED
# form unless the head matches `[0-9a-f]{7,40}` and the repository slug
# matches `[A-Za-z0-9._-]{1,100}/` twice over; the three workflow-side lines
# built it unconditionally, so a run that died before `HEAD_SHA` meant
# anything rendered `[``](https://github.com/<repo>/commit/)` -- a dead link
# under an empty code span, in the one comment class whose whole job is to
# say something went wrong.
#
# TESTED AS A DIFFERENTIAL, not against a transcribed expectation: the two
# renderers are compared to each other on the same inputs, so neither can be
# "fixed" to match a copy in this file. The helper under test is the FILE
# THE WORKFLOW WROTE during the baseline fixtures above, not a copy of it.
HELPER="$WORK/bl_three/publish-comment.sh"
check "the step wrote the shared publish helper" \
  '1' "$([ -s "$HELPER" ] && echo 1 || echo 0)"

# sha_part <rendered line> -> everything before " at ", which is the half
# the two renderers must agree on. The timestamp is each one's own clock.
sha_part() { printf '%s' "${1% at *}"; }

anchor_shell() { # anchor_shell <head> <repo>
  HEAD_SHA="$1" GITHUB_REPOSITORY="$2" bash -c \
    '. "$1" 2>/dev/null && anchor_line' _ "$HELPER" 2>/dev/null
}
anchor_python() { # anchor_python <head> <repo>
  python3 -c 'import sys
sys.path.insert(0, sys.argv[1])
import review_output
print(review_output.anchor(sys.argv[2], "WHEN", sys.argv[3]))' \
    "$HERE" "$1" "$2"
}

# Every shape the validation turns on, and one that it must still link.
while IFS='|' read -r label head repo; do
  [ -n "$label" ] || continue
  check "the anchor line agrees between Python and shell: $label" \
    "$(sha_part "$(anchor_python "$head" "$repo")")" \
    "$(sha_part "$(anchor_shell "$head" "$repo")")"
done <<ANCHORS
a full head and a real slug|1234567890abcdef1234567890abcdef12345678|example-org/consumer
an empty head||example-org/consumer
a head too short to be one|abc123|example-org/consumer
a head that is not hexadecimal|xyz1234|example-org/consumer
no repository at all|1234567890abcdef1234567890abcdef12345678|
a slug with three segments|1234567890abcdef1234567890abcdef12345678|a/b/c
a slug with a space in it|1234567890abcdef1234567890abcdef12345678|a b/c
the shortest head that links|abc1234|example-org/consumer
ANCHORS

# AND NOTHING BUILDS THE LINKED FORM BY HAND ANY MORE. The three notice
# steps each carried their own copy; a fourth would be written the same way
# unless the absence is asserted.
# shellcheck disable=SC2016  # the workflow's literal shell, not an expansion
check "no step builds an anchor link without the validation" \
  '0' "$(grep -cF 'Reviewed [\`${HEAD_SHA:0:7}\`](https://' "$WORKFLOW_FILE")"

# ---------------------------------------------------------------------------
# THE REPO'S OWN CI PLUMBING. Two defects below shipped to `b1e9e3ff` and both
# are silent in the tree: nothing about either file looks wrong when you read
# it. They are here because reading is how they were missed.
# ---------------------------------------------------------------------------

# A suite the lint workflow invokes but cannot execute is a suite that does
# not run, and the failure says `Permission denied` with exit 126 -- which
# reads as an environment problem, not as a missing mode bit in the index.
# `claude/test_review_output.sh` lost its `+x` between `2f77a69` (100755) and
# `b1e9e3ff` (100644) and took the whole job down with it, after every suite
# before it in the list had already printed `ok`.
#
# The list is READ OFF THE WORKFLOW, not restated: a hardcoded copy would
# keep passing for a suite the workflow stopped running, which is the defect
# in the paragraph below this one wearing different clothes.
NOT_EXECUTABLE=""
while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  [ -x "$HERE/../$suite" ] || NOT_EXECUTABLE="$NOT_EXECUTABLE $suite"
done < <(grep -oE '\./claude/[A-Za-z0-9_]+\.sh' "$LINT_WORKFLOW_FILE" | sort -u)
check "every fixture suite the lint workflow runs is executable" \
  '' "$NOT_EXECUTABLE"

# AND NO PROSE COUNT OF THEM, anywhere in that file. The comment above the
# job said "Six shell suites" while the list ran seven, and it went stale in
# the pull request that added the seventh -- the count-invalidation shape
# `claude/pr-prompt-v2.md` promotes to a must-report finding, seventeen
# lines above the guard that reads the list off the file precisely so a
# restated copy cannot go stale. A count a human has to maintain is not a
# convention, it is a latent defect; the list is the count.
check "the lint workflow states no suite count that can go stale" \
  '0' "$(grep -ciE '\b(five|six|seven|eight|nine|[0-9]+) (shell|fixture) suites\b' \
    "$LINT_WORKFLOW_FILE")"

# And the other direction: a suite that exists and is never invoked is the
# exact hole this file was written to close -- six suites covered the helpers
# and nothing covered the workflow, so there was nothing that could fail.
UNWIRED=""
for path in "$HERE"/test_*.sh; do
  name="./claude/$(basename "$path")"
  grep -qF -- "$name" "$LINT_WORKFLOW_FILE" || UNWIRED="$UNWIRED $name"
done
check "every fixture suite present on disk is wired into the lint workflow" \
  '' "$UNWIRED"

# ---------------------------------------------------------------------------
# THE MODEL'S TOOL GRANT, PINNED
# ---------------------------------------------------------------------------
#
# This is the reviewer's whole attack surface outside `Read`/`Glob`/`Grep`:
# a model that has just read an untrusted diff, deciding what to run. Every
# `Bash` grant is a wrapper because `Bash(cmd:*)` bounds the START of the
# command string and nothing after it, and each wrapper is one more program
# that has to stay sound about its own argv.
#
# A LITERAL LIST, not a property. "Each grant names a wrapper that exists"
# would pass for any number of them, and the number is the thing worth
# noticing: a grant added here reaches every consuming repository at once,
# with no pull request to any of them. `review-note` was the second one and
# is gone, because the evidence it carried is a required property of the
# structured output now.
#
# READ OFF THE ASSIGNMENT, not off the step. The first form grepped the
# whole extracted shell and matched `Bash(cmd:*)` out of the comment that
# explains why wrappers exist -- a fixture reading the prose beside the
# value instead of the value.
REVIEW_STEP="$WORK/review_step.sh"
extract_step "Run Claude Code Review" > "$REVIEW_STEP"
check "the reviewer step's shell was found in the workflow file" \
  '1' "$([ -s "$REVIEW_STEP" ] && echo 1 || echo 0)"
check "the reviewer is granted exactly one Bash wrapper" \
  'Bash(review-git:*)' \
  "$(grep -E '^ALLOWED_TOOLS=' "$REVIEW_STEP" \
    | grep -oE 'Bash\([a-z-]+:\*\)' | sort -u | paste -sd' ' -)"

# AND THE PRIVATE BIN HOLDS EXACTLY THE PROGRAMS THOSE GRANTS NAME. The two
# live in different steps, so they can drift in either direction: a grant
# with no program is a tool call that fails for the model, and a program
# with no grant is one copied onto PATH that nobody asked to be runnable.
INSTALL_STEP="$WORK/install_step.sh"
extract_step "Install Claude Code CLI" > "$INSTALL_STEP"
check "the install step's shell was found in the workflow file" \
  '1' "$([ -s "$INSTALL_STEP" ] && echo 1 || echo 0)"
check "the private bin holds exactly the programs the grants name" \
  "$(grep -E '^ALLOWED_TOOLS=' "$REVIEW_STEP" | grep -oE 'Bash\([a-z-]+:' \
    | sed 's/Bash(//; s/:$//' | sort -u | paste -sd' ' -)" \
  "$(grep -E '^(cp|chmod) ' "$INSTALL_STEP" | grep -oE 'RUNNER_TEMP/bin/[a-z-]+' \
    | sed 's|.*/||' | sort -u | paste -sd' ' -)"

# super-linter resolves the actionlint config as
# `${LINTER_RULES_PATH}/${GITHUB_ACTIONS_CONFIG_FILE}` and that variable
# defaults to `actionlint.yml` -- `lib/globals/linterRules.sh`, tag `v8.7.0`.
# Spelled `.yaml`, `GetLinterRules` does not complain: it silently falls back
# to the config baked into the image, so the scoped ignores do not apply and
# the job fails on precisely the errors the file exists to suppress. That
# shipped at `b1e9e3ff`.
#
# The asymmetry is real and is the trap: the sibling `zizmor.yaml` IS `.yaml`,
# because `GITHUB_ACTIONS_ZIZMOR_CONFIG_FILE` defaults to `zizmor.yaml`.
# Anyone making the two consistent breaks one of them.
LINTERS_DIR="$HERE/../.github/linters"
check "the actionlint config uses the extension super-linter resolves" \
  'yes' "$([ -f "$LINTERS_DIR/actionlint.yml" ] && echo yes || echo no)"
check "and the extension super-linter ignores is not present" \
  'no' "$([ -f "$LINTERS_DIR/actionlint.yaml" ] && echo yes || echo no)"
check "the zizmor config keeps its own, different extension" \
  'yes' "$([ -f "$LINTERS_DIR/zizmor.yaml" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# The prompt's contradictory-instruction hazard, asserted on the FILE.
# ---------------------------------------------------------------------------
#
# A path can be BOTH truncated and restored. The truncated paragraph sends
# the reviewer to the working tree for the rest of the change; at a restored
# path the working tree holds the BASE's content, so the remainder is
# reachable nowhere and reading the tree invites findings against the base.
# The restored paragraph is the correct, more specific statement, so it has
# to be the one the model reads LAST -- and it has to say so.
#
# Asserted by line order in the workflow file rather than by running the
# step: these are two `echo ... >> prompt.md` lines whose order in the file
# IS their order in the prompt, and a test that rebuilt the prompt would be
# a second copy of the step rather than a check on it. `filter_diff.py`
# cannot make this correction itself -- it is deliberately never told the
# restored set -- so the workflow is the only place it can live.
# `|| true` INSIDE the substitution, not a default after it. This suite
# runs `set -euo pipefail`: a `grep` that matches nothing fails the
# pipeline, the assignment inherits that status, and the script DIES THERE
# -- before any default is applied and before any of the checks below run.
# Measured by deleting the TRUNCATED_SUMMARY line from a copy of the
# workflow: exit 1, no FAIL line, no "tests FAILED" line, four assertions
# silently unrun. An earlier version of this comment claimed the trailing
# defaults prevented that; they are evaluated too late to prevent anything.
#
# The shape generalises: ANY `X=$(grep ...)` in a suite like this one. `grep
# -c` is the sharpest case, because a legitimate count of zero exits 1.
TRUNC_LINE=$(grep -n 'TRUNCATED_SUMMARY:-' "$WORKFLOW_FILE" | head -1 | cut -d: -f1 || true)
REST_LINE=$(grep -n 'RESTORED_PATHS:-}" \]; then' "$WORKFLOW_FILE" | head -1 | cut -d: -f1 || true)
TRUNC_LINE=${TRUNC_LINE:-0}
REST_LINE=${REST_LINE:-0}
# `-gt 0`, not `-n`: after the defaulting above neither is ever empty, so a
# `-n` test is a tautology that cannot fail however broken the workflow is.
check "the prompt names a truncated-files paragraph" \
  '1' "$([ "$TRUNC_LINE" -gt 0 ] && echo 1 || echo 0)"
check "and a restored-paths paragraph" \
  '1' "$([ "$REST_LINE" -gt 0 ] && echo 1 || echo 0)"
check "the restored paragraph is emitted AFTER the truncated one" \
  '1' "$([ "$REST_LINE" -gt "$TRUNC_LINE" ] && echo 1 || echo 0)"
check "and it overrides the working-tree instruction above it" \
  '1' "$(sed -n "${REST_LINE},\$p" "$WORKFLOW_FILE" | head -3 \
         | grep -c 'overrides anything above that sends you to the working tree')"
check "and it names the truncated overlap explicitly" \
  '1' "$(sed -n "${REST_LINE},\$p" "$WORKFLOW_FILE" | head -3 \
         | grep -c 'also in the truncated list')"
# AND IT NO LONGER ASSERTS WHAT THE PATCH BLOCK CAN CONTRADICT. ~~"Their
# patches are supplied in this prompt"~~ is false when the budget dropped a
# restored path's patch, and the patch block that says so is appended after
# this paragraph.
check "and it concedes that a restored patch may not be supplied" \
  '1' "$(sed -n "${REST_LINE},\$p" "$WORKFLOW_FILE" | head -3 \
         | grep -c 'unless the \*\*Not supplied here\*\* list names them')"

# ---------------------------------------------------------------------------
# THE PATCHES ARE IN THE PROMPT, and the order of the three steps that put
# them there is the thing to pin.
# ---------------------------------------------------------------------------
#
# Measured: at nine or more changed files the reviewer issued ZERO Read calls
# and posted a clean verdict anyway, at 5% context occupancy over 5-6 turns.
# It was not short of window. So the content arrives rather than being
# fetched, and three properties of that have to hold in the FILE, because
# none of them can be tested by running the step without a manifest, a
# checkout and a CLI:
#
#   1. The block is rendered, appended, and only THEN verified -- verifying
#      before the append would check a prompt that is not the one sent.
#   2. The thread still goes last, immediately before "Begin.". Its rules are
#      established by the prompt above it, and the patch block must not get
#      between them.
#   3. The verification reads prompt.md, not the block.
#
# `|| true` INSIDE each substitution, and a numeric default after it, for the
# reason the header of the previous section gives: this suite runs
# `set -euo pipefail`, so a `grep` matching nothing takes the script down at
# the assignment, before any assertion below it runs.
PATCH_RENDER_LINE=$(grep -n 'patch_block.py render' "$WORKFLOW_FILE" | head -1 | cut -d: -f1 || true)
PATCH_APPEND_LINE=$(grep -n 'patches.md" >> "' "$WORKFLOW_FILE" | head -1 | cut -d: -f1 || true)
PATCH_VERIFY_LINE=$(grep -n 'patch_block.py verify' "$WORKFLOW_FILE" | head -1 | cut -d: -f1 || true)
DISCUSSION_LINE=$(grep -n 'discussion.md" >> "' "$WORKFLOW_FILE" | head -1 | cut -d: -f1 || true)
BEGIN_LINE=$(grep -n "printf '.nBegin..n'" "$WORKFLOW_FILE" | head -1 | cut -d: -f1 || true)
PATCH_RENDER_LINE=${PATCH_RENDER_LINE:-0}
PATCH_APPEND_LINE=${PATCH_APPEND_LINE:-0}
PATCH_VERIFY_LINE=${PATCH_VERIFY_LINE:-0}
DISCUSSION_LINE=${DISCUSSION_LINE:-0}
BEGIN_LINE=${BEGIN_LINE:-0}

check "the prompt step renders the patch block" \
  '1' "$([ "$PATCH_RENDER_LINE" -gt 0 ] && echo 1 || echo 0)"
check "and appends it to the prompt" \
  '1' "$([ "$PATCH_APPEND_LINE" -gt "$PATCH_RENDER_LINE" ] && echo 1 || echo 0)"
check "and verifies it only once it is in the prompt" \
  '1' "$([ "$PATCH_VERIFY_LINE" -gt "$PATCH_APPEND_LINE" ] && echo 1 || echo 0)"
check "the patches are appended before the thread" \
  '1' "$([ "$DISCUSSION_LINE" -gt "$PATCH_APPEND_LINE" ] && echo 1 || echo 0)"
check "and the thread is still the last thing before Begin." \
  '1' "$([ "$BEGIN_LINE" -gt "$DISCUSSION_LINE" ] && echo 1 || echo 0)"

# THE FILE THAT WAS SENT, not the block. The prompt is assembled from several
# pieces and a step that appended the wrong one would pass a check against
# the block alone.
# shellcheck disable=SC2016  # the workflow's literal shell, not an expansion
check "the verification reads the prompt, not the block" \
  '1' "$(sed -n "${PATCH_VERIFY_LINE},\$p" "$WORKFLOW_FILE" | head -2 \
         | grep -c '"\$RUNNER_TEMP/prompt.md" "\$RUNNER_TEMP/supplied.tsv"')"

# NOT BEST-EFFORT. The thread degrades to a review without it; the patches
# ARE the change, so a failure to render them has to become the
# review-unavailable comment rather than a reviewer with no diff.
check "a failed render is an error outcome, not a warning and carry on" \
  '1' "$(sed -n "${PATCH_RENDER_LINE},\$p" "$WORKFLOW_FILE" | head -12 \
         | grep -c 'REVIEW_OUTCOME=error')"
check "and so is a verification that fails" \
  '1' "$(sed -n "${PATCH_VERIFY_LINE},\$p" "$WORKFLOW_FILE" | head -10 \
         | grep -c 'REVIEW_OUTCOME=error')"

# THE BYTE BUDGET HAS A BACKSTOP AND IT HAS TO BITE. The budget above is
# arithmetic over three measurements; the assertion is against the file
# actually sent. A `::warning::` and carry on sends the oversize prompt
# anyway, the CLI refuses it before any API call -- "Prompt is too long",
# duration_api_ms 0 -- and the job dies with no comment posted.
OVERSIZE_LINE=$(grep -n 'bytes against a max_prompt_bytes of' "$WORKFLOW_FILE" \
  | head -1 | cut -d: -f1 || true)
OVERSIZE_LINE=${OVERSIZE_LINE:-0}
check "an oversize prompt is detected against the assembled file" \
  '1' "$([ "$OVERSIZE_LINE" -gt 0 ] && echo 1 || echo 0)"
check "and it is an error outcome, not a warning and carry on" \
  '1' "$(sed -n "${OVERSIZE_LINE},\$p" "$WORKFLOW_FILE" | head -6 \
         | grep -c 'REVIEW_OUTCOME=error')"
check "and it stops before the CLI is reached" \
  '1' "$(sed -n "${OVERSIZE_LINE},\$p" "$WORKFLOW_FILE" | head -6 \
         | grep -c 'exit 0')"
check "and the error names both byte counts" \
  '1' "$(sed -n "${OVERSIZE_LINE},\$p" "$WORKFLOW_FILE" | head -6 \
         | grep -c 'REVIEW_ERROR=.*against a max_prompt_bytes of')"

# THE RESERVED TAIL IS WHAT IS COUNTED NOWHERE ELSE, and a constant that
# disagreed with its own comment is a byte the budget does not know about.
# Measured: a newline before the block, one before the thread and
# "\nBegin.\n" is 1 + 1 + 8.
check "the reserved tail is the measured ten bytes" \
  '1' "$(grep -c '^ *PROMPT_TAIL_BYTES=10$' "$WORKFLOW_FILE")"
check "and the comment above it accounts for all ten" \
  '1' "$(grep -B4 '^ *PROMPT_TAIL_BYTES=10$' "$WORKFLOW_FILE" \
         | grep -c '8 for ')"

# THE SUPPLY PAIR IN THE MARKER COMES FROM THE LEDGER, not from the
# manifest. review_output.py's own count is over OPENABLE rows, which is no
# longer the population `read=` divides by, so the two fields on one comment
# were called `supplied` and counted different things.
# shellcheck disable=SC2016  # a literal workflow expression under test
check "the adjudicator is given the ledger's supply counts" \
  '1' "$(grep -c -- '--supply-total "\${SUPPLY_TOTAL:-}"' "$WORKFLOW_FILE")"
# shellcheck disable=SC2016  # a literal workflow expression under test
check "and its supplied half" \
  '1' "$(grep -c -- '--supply-supplied "\${SUPPLY_SUPPLIED:-}"' "$WORKFLOW_FILE")"

# ONE SCHEMA TOKEN, READ OFF THE PROGRAM THAT WRITES IT. The four
# non-reviewed lanes hard-code their marker in this file; a bump in
# review_output.py that missed them would put two schemas on one pull
# request, which is exactly what the token exists to prevent.
MARKER_VERSION=$(sed -n 's/.*<!-- claude-review \(v[0-9]*\) lane={lane}.*/\1/p' \
  "$HERE/review_output.py" | head -1 || true)
check "review_output.py declares a marker version" \
  '1' "$([ -n "$MARKER_VERSION" ] && echo 1 || echo 0)"
check "and every hard-coded lane marker carries the same one" \
  '4' "$(grep -c "<!-- claude-review ${MARKER_VERSION} lane=" "$WORKFLOW_FILE")"
check "and no other schema token is left behind" \
  "$MARKER_VERSION" "$(grep -o '<!-- claude-review v[0-9]* lane=' "$WORKFLOW_FILE" \
         | awk '{print $3}' | sort -u | paste -sd, -)"

# THE BUDGET REACHES THE RENDERER. An unset MAX_PATCH_BLOCK_BYTES is
# patch_block.py's "no backstop", so a budget that did not arrive would send
# an unbounded prompt -- which the CLI refuses before any API call, with no
# review and nothing to retry.
# shellcheck disable=SC2016  # the workflow's literal shell, not an expansion
check "the renderer is given the computed budget" \
  '1' "$(grep -c 'MAX_PATCH_BLOCK_BYTES="\$PATCH_BLOCK_BUDGET"' "$WORKFLOW_FILE")"
# shellcheck disable=SC2016  # a literal workflow expression under test
check "the budget is derived from max_prompt_bytes" \
  '1' "$(grep -c 'PATCH_BLOCK_BUDGET=\$((MAX_PROMPT_BYTES - PROMPT_BASE_BYTES' "$WORKFLOW_FILE")"
# shellcheck disable=SC2016  # a literal workflow expression under test
check "and a remainder that ran out becomes 1, not 0" \
  '1' "$(sed -n '/PATCH_BLOCK_BUDGET=\$((MAX_PROMPT_BYTES/,+8p' "$WORKFLOW_FILE" \
         | grep -c 'PATCH_BLOCK_BUDGET=1')"

# ITS OWN NONCE. A shared value would make the thread's sanitising and the
# patches' deliberate lack of it two uses of one key.
# shellcheck disable=SC2016  # a literal workflow expression under test
check "the patch fence carries a nonce of its own" \
  '1' "$(grep -c 'PATCH_NONCE=\$(head -c 8 /dev/urandom' "$WORKFLOW_FILE")"
# shellcheck disable=SC2016  # a literal workflow expression under test
check "and it is not the thread's" \
  '1' "$(grep -c 'DISCUSSION_NONCE=\$(head -c 8 /dev/urandom' "$WORKFLOW_FILE")"
# AND BOTH GUARDS VALIDATE WHAT THEY LOOK LIKE THEY VALIDATE.
# ~~`[0-9a-f][0-9a-f]*`~~ checked the first two characters and accepted
# anything after them. `review_io.run_nonce` is the authority either way, so
# this was never exploitable -- but a guard that reads as a hex check and is
# not one is the next thing somebody trusts.
check "the thread nonce guard rejects a non-hex character anywhere" \
  '1' "$(grep -cF '*[!0-9a-f]*) DISCUSSION_NONCE="" ;;' "$WORKFLOW_FILE")"
check "and the patch nonce guard does too" \
  '1' "$(grep -cF '*[!0-9a-f]*) PATCH_NONCE="" ;;' "$WORKFLOW_FILE")"
check "and both require at least eight characters" \
  '2' "$(grep -cF '????????*) ;;' "$WORKFLOW_FILE")"
check "and the two-character pattern is gone" \
  '0' "$(grep -cF '[0-9a-f][0-9a-f]*) ;;' "$WORKFLOW_FILE" || true)"

# SUPPLY SURVIVES A COVERAGE FAILURE. The section row above is written
# unconditionally from patch_block.py's log, so a marker reading
# `supplied=unmeasured/unmeasured` beside "14 of 16 file(s) with a patch"
# puts two accounts of one number on one comment. The log is still on disk.
# shellcheck disable=SC2016  # a literal workflow expression under test
check "a failed coverage run still reports supply from the patch-block log" \
  '1' "$(grep -cF 'echo "SUPPLY_TOTAL=${SUPPLY_FILES}"' "$WORKFLOW_FILE")"
# shellcheck disable=SC2016  # a literal workflow expression under test
check "and its supplied half, from the same file" \
  '1' "$(grep -cF 'echo "SUPPLY_SUPPLIED=${SUPPLY_IN}"' "$WORKFLOW_FILE")"
check "guarded so a non-numeric pair writes nothing at all" \
  '1' "$(grep -cF '*[!0-9:]* | :* | *:) ;;' "$WORKFLOW_FILE")"

# THE LEDGER REACHES THE COVERAGE CHECK. Without it every supplied row goes
# back in the read population and the comment reports a measured zero on a
# review that was handed everything.
# shellcheck disable=SC2016  # a literal workflow expression under test
check "the coverage check is given the supply ledger" \
  '1' "$(grep -c -- '--supplied "\$RUNNER_TEMP/supplied.tsv"' "$WORKFLOW_FILE")"

# AND BOTH NUMBERS REACH THE PULL REQUEST. The supplied row is the one
# disclosure written unconditionally: it is what a human now reads in place
# of `read=R/T`, whose denominator has become the rows still to be fetched.
check "the comment discloses how many patches were supplied" \
  '1' "$(grep -c "printf 'Patches supplied in the prompt" "$WORKFLOW_FILE")"
check "and names the ones the budget dropped" \
  '1' "$(grep -c 'Patch not supplied in the prompt' "$WORKFLOW_FILE")"
# AND THE ROWS WHOSE PATCH FILE WOULD NOT OPEN, which is a different reason
# from the budget and reaches the comment under its own label: the row above
# names `max_prompt_bytes` and would be the wrong explanation.
check "and the ones whose patch file could not be read" \
  '1' "$(grep -c 'Patch file could not be read' "$WORKFLOW_FILE")"
check "read off the log line patch_block.py writes for them" \
  '1' "$(grep -cF "capped_list '  ? '" "$WORKFLOW_FILE")"
check "and the dropped list off its own line" \
  '1' "$(grep -cF "capped_list '  % '" "$WORKFLOW_FILE")"
check "both through the capping helper, not a bare head -- defined once" \
  '3' "$(grep -cF 'capped_list ' "$WORKFLOW_FILE")"
# NEITHER LIST IS SILENTLY TRUNCATED. ~~`head -20` alone~~ rendered 25
# dropped patches as 20 names and five omissions nobody was told about,
# under a program whose own docstring says a budget that could silence the
# list of what it dropped would hide exactly what it did. Same `(+N more)`
# shape as `list_from`, counted off the log's own count lines.
# TWO, because `list_from` in the prompt step already had it: the point is
# that both helpers now disclose the same way rather than one of them
# truncating in silence.
# shellcheck disable=SC2016  # a literal workflow expression under test
check "a list past twenty says how many it is not showing, in both helpers" \
  '2' "$(grep -cF 'LIST="${LIST} (+$(($2 - 20)) more)"' "$WORKFLOW_FILE")"
# shellcheck disable=SC2016  # a literal workflow expression under test
check "and the count comes from patch_block.py own report lines" \
  '1' "$(grep -cF 'Patch block $1: ' "$WORKFLOW_FILE")"

# THE HELPER MUST BE IN THE CHECKOUT GUARD, or the first run on a consumer
# fails inside python with a traceback instead of the review-unavailable
# comment the other nine helpers get.
# READ OFF THE LIST, not off the file: `claude/patch_block.py` also appears
# in the two commands that run it, so a whole-file count passes whether or
# not the guard knows about it.
check "patch_block.py is checked for like every other helper" \
  '1' "$(awk '/^ *for f in claude\//,/; do$/' "$GUARD" \
    | grep -c 'claude/patch_block.py' || true)"

# AND THE PROMPT MUST NOT STILL SAY THE OPPOSITE. "No diff is pasted into
# this prompt" was true and is now the first thing a reader of the file
# would believe.
PROMPT_FILE="$HERE/pr-prompt-v2.md"
check "the prompt no longer says no diff is pasted into it" \
  '0' "$(grep -c 'No diff is pasted into this prompt' "$PROMPT_FILE" || true)"
check "and says the patches are in it" \
  '1' "$(grep -c '^Four things\. \*\*The patches are in this prompt\*\*' "$PROMPT_FILE")"
# A TRUNCATED ROW IS THE EXCEPTION TO "the only rows left for you to fetch
# are the ones it names". It is in `patch_block.IN_PROMPT`, so the
# disclosure does not name it, and `review_coverage.measure` deliberately
# keeps it in the read population -- so a model trusting the absolute form
# skipped the row and was then named unopened on the pull request.
check "the prompt does not claim the named rows are the only ones to fetch" \
  '0' "$(grep -c 'the only rows left for you to fetch are the ones it names' \
    "$PROMPT_FILE" || true)"
check "and names the truncated row as the exception" \
  '1' "$(grep -c "manifest's fifth column marks \`truncated\`\*\*" "$PROMPT_FILE")"

if [ "$FAILED" -ne 0 ]; then
  echo "review workflow tests FAILED" >&2
  exit 1
fi
echo "review workflow tests passed"
