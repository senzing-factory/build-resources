#!/usr/bin/env bash
# cspell:ignore inrun  -- an awk local, not vocabulary
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
# The ten helper files are created too, because the same step checks for
# them: without them these fixtures would fail on the file check and report
# a ref problem that is not there.
mk_checkout() { # mk_checkout <dir>
  mkdir -p "$1/build-resources/claude"
  for f in pr-prompt-v2.md filter_diff.py pr_discussion.py review_io.py \
    review-schema.json review_coverage.py review_output.py review_text.py \
    review-note review-git; do
    : > "$1/build-resources/claude/$f"
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

if [ "$FAILED" -ne 0 ]; then
  echo "review workflow tests FAILED" >&2
  exit 1
fi
echo "review workflow tests passed"
