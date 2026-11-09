#!/usr/bin/env bash
# cspell:ignore inrun unrun inkey  -- awk locals and a comment's own word
# cspell:ignore UNMEAS noverdict NOGATE nogate ungated NOSTAMP nostamp
# cspell:ignore cksum BADSHAPE badshape notfindings
# -- fixture case names, and the checksum tool macOS has
# -- none of these is vocabulary
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

# The `if:` expression of one named step, with any `${{ }}` wrapper and the
# surrounding whitespace removed. A step's condition is as load-bearing as
# its shell and `extract_step` never sees it: it runs the body, which Actions
# would not have run at all.
extract_step_if() { # extract_step_if <step name> -> the condition it carries
  awk -v want="      - name: $1" '
    $0 == want { instep = 1; next }
    instep && /^      - name: / { exit }
    instep && /^        if: / {
      sub(/^        if: /, "")
      sub(/^\$\{\{[[:space:]]*/, "")
      sub(/[[:space:]]*\}\}$/, "")
      print
      exit
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

# ---------------------------------------------------------------------------
# THE SECOND REVIEW PASS
# ---------------------------------------------------------------------------
#
# WHAT IT IS FOR. The reviewer is handed a manifest and chooses which rows to
# `Read`, so coverage is a model decision. Across four consecutive pushes of
# one pull request -- same lane, every patch supplied, nothing withheld by any
# cap -- it opened 9, 11, 18 and 20 of roughly 45 rows, and the 20-row run
# returned a clean verdict having opened none of fourteen newly added CI
# workflow files. The unopened set is already computed exactly, so it is
# written back out as a manifest and handed to one more invocation.
#
# THE THREE STEPS ARE EXTRACTED AND RUN, not restated. A copy of their shell
# here would keep passing while the workflow drifted, which is this file's
# founding defect.

SECOND_MANIFEST_STEP="$WORK/second_manifest.sh"
extract_step "Build the second-pass manifest" > "$SECOND_MANIFEST_STEP"
check "the second-pass manifest step's shell was found in the workflow file" \
  '1' "$([ -s "$SECOND_MANIFEST_STEP" ] && echo 1 || echo 0)"

SECOND_RUN_STEP="$WORK/second_run.sh"
extract_step "Run the second review pass" > "$SECOND_RUN_STEP"
check "the second-pass run step's shell was found in the workflow file" \
  '1' "$([ -s "$SECOND_RUN_STEP" ] && echo 1 || echo 0)"

SECOND_MEASURE_STEP="$WORK/second_measure.sh"
extract_step "Measure coverage across both passes" > "$SECOND_MEASURE_STEP"
check "the both-passes coverage step's shell was found in the workflow file" \
  '1' "$([ -s "$SECOND_MEASURE_STEP" ] && echo 1 || echo 0)"

# THE JOB'S OWN BOUND, read off the file in both of its spellings. It is
# needed this early because every fixture that runs the second-pass step has
# to supply it: that step now refuses to start without knowing how much of
# the job is left. See the budget block below for why.
JOB_TIMEOUT=$(sed -n 's/^    timeout-minutes: \([0-9]*\)$/\1/p' "$WORKFLOW_FILE" | head -1)
JOB_TIMEOUT_ENV=$(sed -n 's/^      JOB_TIMEOUT_MINUTES: \([0-9]*\)$/\1/p' "$WORKFLOW_FILE" | head -1)
check "the job bound was found in the workflow file" \
  '1' "$([ -n "$JOB_TIMEOUT" ] && echo 1 || echo 0)"
check "and so was the value the shell reads" \
  '1' "$([ -n "$JOB_TIMEOUT_ENV" ] && echo 1 || echo 0)"
check "the two copies of the job bound agree" "$JOB_TIMEOUT" "$JOB_TIMEOUT_ENV"

# The MEASURED shape: 45 manifest rows, of which the first pass opened 20.
# `missing` names a row the uncovered list claims and the manifest does not,
# which is the short-join case.
mk_pass_dir() { # mk_pass_dir <case> <unopened count> [missing]
  local dir="$WORK/sp_$1" n="$2" i
  mkdir -p "$dir/pr-files" "$dir/tmp" "$dir/build-resources/claude"
  # pr_discussion.py is here because `review_text.py --digest` imports it
  # for the fence it shares with the comment thread. The workflow's own
  # "Verify build resources checkout" already requires the file, so a run
  # that reached this step always has it.
  for f in review_text.py review_io.py review_coverage.py pr_discussion.py; do
    cp "$HERE/$f" "$dir/build-resources/claude/$f"
  done
  : > "$dir/pr-files/manifest.tsv"
  i=1
  while [ "$i" -le 45 ]; do
    printf 'modified\t%s\tsrc/f%s.go\tpr-files/%04d.patch\n' \
      "$((i + 1))" "$i" "$i" >> "$dir/pr-files/manifest.tsv"
    i=$((i + 1))
  done
  : > "$dir/tmp/uncovered.txt"
  i=$((45 - n + 1))
  while [ "$i" -le 45 ]; do
    printf 'src/f%s.go\n' "$i" >> "$dir/tmp/uncovered.txt"
    i=$((i + 1))
  done
  [ "${3:-}" = "missing" ] && printf 'src/not-in-the-manifest.go\n' >> "$dir/tmp/uncovered.txt"
  : > "$dir/tmp/github.env"
  {
    # SC2016 reads the backticks as command substitution; they are the
    # markdown the real step writes, and the label is matched verbatim.
    # shellcheck disable=SC2016
    printf 'Not reviewed (dropped by `exclude_globs`)\tyarn.lock\n'
    printf 'Files the reviewer did not open (20 of 45 openable opened)\tsrc/f21.go [PATCH]\n'
  } > "$dir/tmp/sections.tsv"
  printf '{"findings":[]}\n' > "$dir/tmp/review.txt"
  printf 'INSTRUCTION TEXT\n\n## Run context\n\nthe discussion goes here\n' \
    > "$dir/tmp/prompt-common.md"
  cat "$dir/tmp/prompt-common.md" > "$dir/tmp/prompt.md"
  printf '\nBegin.\n' >> "$dir/tmp/prompt.md"
  # 444, BECAUSE PRODUCTION MAKES IT 444. The fixtures wrote it 0644 and so
  # could not see the mode at all -- and this suite runs as root, where a
  # 444 file is writable anyway, so even a mode-blind write would have
  # passed. Both halves have to be right for the assertions below to mean
  # anything: production's mode here, and a test on the MODE BITS there.
  chmod 444 "$dir/tmp/prompt-common.md"
  printf '%s' "$dir"
}

run_manifest_step() { # run_manifest_step <dir> <COVERAGE_UNCOVERED>
  # `-eo pipefail`. `-e` IS what Actions does -- no step here sets `shell:`
  # and there is no `defaults.run.shell`, so these run as `bash -e {0}`.
  # `pipefail` is STRICTER than production, deliberately: it is the safe
  # direction for a fixture, and every assertion in this file was re-run
  # under `-e` alone with no divergence. Without `-e` a step that fails
  # halfway would run on to its end here and the fixture would measure a
  # path production never takes.
  ( cd "$1" && RUNNER_TEMP="$1/tmp" GITHUB_ENV="$1/tmp/github.env" \
      COVERAGE_UNCOVERED="$2" \
      bash -eo pipefail "$SECOND_MANIFEST_STEP" \
      > "$1/tmp/manifest_log.txt" 2>&1 ) || true
}

env_of() { # env_of <dir> <key> -> the last value written, or ""
  sed -n "s/^$2=//p" "$1/tmp/github.env" | tail -1
}

# ---------------------------------------------------------------------------
# FIXTURE 1. A pull request the first pass covered in full costs nothing.
#
# This is the hard constraint the whole design sits under: roughly 170
# repositories take this workflow at a floating major tag, so a run that did
# not need a second pass must produce what it has always produced. No
# manifest, no gate variable, and therefore -- the next step is gated on that
# variable -- no second invocation.
# ---------------------------------------------------------------------------
FULL=$(mk_pass_dir full 25)
run_manifest_step "$FULL" 0
check "full first-pass coverage builds no second manifest" \
  '0' "$([ -e "$FULL/pr-files/manifest-2.tsv" ] && echo 1 || echo 0)"
check "and sets no gate variable, so no second invocation can run" \
  '' "$(env_of "$FULL" SECOND_PASS_ROWS)"
check "and writes nothing to the environment file at all" \
  '0' "$(wc -c < "$FULL/tmp/github.env" | tr -d ' ')"
# READ OFF THE WORKFLOW, AND AS THE WHOLE CONDITION. ~~A file-wide
# `grep -cF` for the literal~~ was the weakest of the three gate
# assertions and sat on the step that spends the money: changing `&&` to
# `||` leaves the literal in place and runs a full `claude -p` on every
# reviewed pull request in every consumer, `second_pass: false` included,
# because the outcome test is true on its own. A `grep` also matches the
# literal in a COMMENT, which is the failure this file already guards
# against for the self-pin a few assertions below.
check "the second-pass run step is gated on that variable being set" \
  "env.REVIEW_OUTCOME == 'reviewed' && env.SECOND_PASS_ROWS != ''" \
  "$(extract_step_if "Run the second review pass")"

# THE OPT-IN ITSELF, WHICH IS THE LINE WITH THE BLAST RADIUS ON IT.
# `inputs.second_pass` appears exactly once as a gate, and deleting those
# three words from it ships a second `claude -p` per pull request to every
# repository on the floating major tag, with no pull request to any of
# them. Nothing else in this file reads that condition -- every fixture
# below runs the step's shell directly, which is what Actions does only
# AFTER deciding the `if`, so all of them stay green over a reviewer that
# has silently been turned on everywhere. That is the shape this suite was
# written to catch, one step further out.
# AND THE JOIN KEY IS ACTUALLY REQUESTED, BY THE FIRST MEASUREMENT. The
# manifest step reads `uncovered.txt` and `mk_pass_dir` writes it itself,
# so deleting the flag left the whole suite green while production stopped
# at `if [ ! -f ... ]` with a warning nobody reads. ~~A file-wide grep for
# a count of one~~ did not test "the first" either: MOVING the flag to the
# both-passes measurement keeps the count at one and has the same effect,
# since that step only runs after the manifest step has already given up.
# shellcheck disable=SC2016  # a literal shell fragment from the workflow
check "the first coverage measurement asks for the uncovered-row list" \
  '1' "$(extract_step "Measure review coverage" \
    | grep -c -- '--uncovered-file "\$RUNNER_TEMP/uncovered.txt"')"

check "the second-pass manifest step is gated on the opt-in input" \
  "env.REVIEW_OUTCOME == 'reviewed' && inputs.second_pass" \
  "$(extract_step_if "Build the second-pass manifest")"

# AND THE INPUT IS OFF BY DEFAULT, for the reason `coverage_enforcement`
# defaults to `warn` and `max_file_bytes` to 0. A default flipped to true
# has the same blast radius as deleting the gate, arrives the same way, and
# is a one-word diff. The whole `workflow_call` block is one YAML mapping,
# so the default is read as the first `default:` after the input's own key.
# READ AS YAML where a parser is available, which on a GitHub runner it
# always is. An awk rule keyed on today's indentation would report "a
# repository that asks for nothing gets a second pass" after a pure
# re-indentation -- a false alarm on the one assertion that must never cry
# wolf. The awk form stays as the fallback for a machine with no PyYAML,
# where a check that cannot run is worse than an approximate one.
# `on:` IS PARSED AS THE BOOLEAN True, not the string "on" -- YAML 1.1's
# truthy rule, the same one the repo's yamllint config disables. Keying on
# the string made this path raise KeyError on every run and silently fall
# through to the awk below, which is the fixture-passing-for-the-wrong-
# reason shape: the assertion held, and not for the reason it claimed.
SECOND_PASS_DEFAULT=$(python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
triggers = doc.get("on", doc.get(True))
print(triggers["workflow_call"]["inputs"]["second_pass"]["default"])' \
  "$WORKFLOW_FILE" 2> /dev/null \
  || awk '
  /^      second_pass:$/ { inkey = 1; next }
  inkey && /^      [a-z_]+:$/ { exit }
  inkey && /^        default: / { sub(/^        default: /, ""); print; exit }
' "$WORKFLOW_FILE")
# PyYAML renders a YAML boolean as Python's `False`; the awk fallback
# returns the file's own spelling. Both mean the same thing and the
# assertion must accept either rather than depend on which path ran.
SECOND_PASS_DEFAULT=$(printf '%s' "$SECOND_PASS_DEFAULT" | tr '[:upper:]' '[:lower:]')
check "the opt-in input was found with a default" \
  '1' "$([ -n "$SECOND_PASS_DEFAULT" ] && echo 1 || echo 0)"
check "and a repository that asks for nothing gets no second pass" \
  'false' "$SECOND_PASS_DEFAULT"

# AN UNMEASURED RUN IS NOT A SHORTFALL. Every row LOOKS unopened when the
# instrument failed, and re-reviewing the whole change on that basis spends a
# full second review to learn nothing.
UNMEAS=$(mk_pass_dir unmeasured 25)
run_manifest_step "$UNMEAS" unmeasured
check "an unmeasured run builds no second manifest" \
  '0' "$([ -e "$UNMEAS/pr-files/manifest-2.tsv" ] && echo 1 || echo 0)"
check "and runs no second pass over the whole change" \
  '' "$(env_of "$UNMEAS" SECOND_PASS_ROWS)"

# ---------------------------------------------------------------------------
# FIXTURE 2. The second pass is given EXACTLY the rows the first did not open.
# ---------------------------------------------------------------------------
SHORT=$(mk_pass_dir short 25)
run_manifest_step "$SHORT" 25
check "a short first pass builds a manifest of the unopened rows" \
  '25' "$(wc -l < "$SHORT/pr-files/manifest-2.tsv" | tr -d ' ')"
check "and the gate variable names the same count" \
  '25' "$(env_of "$SHORT" SECOND_PASS_ROWS)"
check "the rows are exactly the ones named unopened" \
  '' "$(cut -f3 "$SHORT/pr-files/manifest-2.tsv" | diff - "$SHORT/tmp/uncovered.txt" || echo DIFFERS)"
check "no row the first pass DID open is in it" \
  '0' "$(cut -f3 "$SHORT/pr-files/manifest-2.tsv" | grep -cx 'src/f1.go' || true)"
# VERBATIM, not rebuilt: every column the second reviewer reads is spelled as
# the first reviewer saw it, `changes` and the patch path included.
# Every line of the second manifest is a line of the first, byte for byte.
# `comm -23` prints what is in the left file and not the right; empty means
# nothing was rewritten on the way through.
check "the rows are copied whole, not reconstructed from the path" \
  '' "$(comm -23 \
    <(sort "$SHORT/pr-files/manifest-2.tsv") \
    <(sort "$SHORT/pr-files/manifest.tsv"))"
check "and they keep their changes count and patch path" \
  '1' "$(grep -cxF "$(printf 'modified\t46\tsrc/f45.go\tpr-files/0045.patch')" \
    "$SHORT/pr-files/manifest-2.tsv")"

# A SHORT JOIN IS REFUSED RATHER THAN REVIEWED. A manifest missing a row
# hands the second pass less than it was told about, and the coverage
# re-measurement afterwards would credit what it did get while the rest
# stayed silently unopened.
PARTIAL=$(mk_pass_dir partial 25 missing)
run_manifest_step "$PARTIAL" 26
check "a join that cannot place every named row runs no second pass" \
  '' "$(env_of "$PARTIAL" SECOND_PASS_ROWS)"
check "and leaves no half-built manifest behind for anything to read" \
  '0' "$([ -e "$PARTIAL/pr-files/manifest-2.tsv" ] && echo 1 || echo 0)"
check "and says how many rows it could not place" \
  '1' "$(grep -c '25 of 26' "$PARTIAL/tmp/manifest_log.txt")"

# ---------------------------------------------------------------------------
# Running the pass itself, against a stubbed CLI.
# ---------------------------------------------------------------------------
#
# `run_review` is the function the first-pass step writes to
# `$RUNNER_TEMP/run-review.sh` so that both passes share one invocation. The
# stub replaces that file, which is also what proves the second step calls it
# rather than building its own `claude` command line.
stub_runner() { # stub_runner <dir>
  cat > "$1/tmp/run-review.sh" <<'STUB'
run_review() {
  cp "$STUB_TRANSCRIPT" "$2"
  : > "$3"
  return "${STUB_STATUS:-0}"
}
STUB
}

run_second_pass() { # run_second_pass <dir> <transcript> <exit status>
  stub_runner "$1"
  # A JOB THAT HAS JUST STARTED, so these fixtures exercise the pass itself
  # and not the budget arithmetic; the budget block below winds the clock
  # back deliberately.
  ( cd "$1" && RUNNER_TEMP="$1/tmp" GITHUB_ENV="$1/tmp/github.env" \
      SECOND_PASS_ROWS=25 COVERAGE_READ=20 COVERAGE_TOTAL=45 \
      JOB_TIMEOUT_MINUTES="$JOB_TIMEOUT_ENV" JOB_STARTED_AT="$(date +%s)" \
      STUB_TRANSCRIPT="$2" STUB_STATUS="$3" \
      bash -eo pipefail "$SECOND_RUN_STEP" > "$1/tmp/run_log.txt" 2>&1 ) || true
}

# A transcript of the second pass opening every row it was given. `read_ok`
# here mirrors the real envelope: the call, then the result that says the
# read returned something.
sp_call() { # sp_call <id> <path>
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"Read","input":{"file_path":"%s"}}]}}\n' "$1" "$2"
}
sp_result() { # sp_result <id>
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","content":"1 x"}]}}\n' "$1"
}
WS=/home/runner/work/repo/repo
sp_reads() { # sp_reads -- reads of all 25 second-pass rows
  local i=21
  while [ "$i" -le 45 ]; do
    sp_call "r$i" "$WS/pr-files/$(printf '%04d' "$i").patch"
    sp_result "r$i"
    i=$((i + 1))
  done
}
SP_FINDING='{"severity":"BLOCKER","path":"src/f30.go","line":4,"message":"The new workflow checks out the head ref under pull_request_target. Pin it to the base."}'
{
  sp_reads
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"findings":[%s]}}\n' \
    "$SP_FINDING"
} > "$WORK/sp_good.jsonl"
# THE DANGEROUS TRANSCRIPT: every row read, and no verdict about any of them.
{
  sp_reads
  printf '{"type":"result","subtype":"success","is_error":false}\n'
} > "$WORK/sp_noverdict.jsonl"

# ---------------------------------------------------------------------------
# The prompt: a strict extension of the first pass's, with the assignment last
# ---------------------------------------------------------------------------
GOOD=$(mk_pass_dir good 25)
run_manifest_step "$GOOD" 25
run_second_pass "$GOOD" "$WORK/sp_good.jsonl" 0
COMMON_BYTES=$(wc -c < "$GOOD/tmp/prompt-common.md" | tr -d ' ')
check "the second prompt opens with the shared prefix, byte for byte" \
  "$(cksum < "$GOOD/tmp/prompt-common.md")" \
  "$(head -c "$COMMON_BYTES" "$GOOD/tmp/prompt-2.md" | cksum)"
check "and that shared prefix is not empty" \
  '1' "$([ "$COMMON_BYTES" -gt 0 ] && echo 1 || echo 0)"

# THE MODE OF EVERY PROMPT THIS JOB WRITES, measured against the REAL
# steps rather than against files this suite wrote for itself.
#
# `prompt-common.md` is deliberately 444, and `cp` gives a destination the
# SOURCE's mode bits -- so a prompt built with `cp` is one nothing can
# append to, and on a GitHub-hosted runner that is `Permission denied` for
# uid 1001 and an ERR trap on every consumer. Reproduced end to end as a
# non-root user. MODE BITS, not `[ -w ]`: these fixtures run as root,
# which may write a 444 file, so a `-w` test cannot fail however broken
# the step is. The owner write bit is the THIRD character of `-rw-r--r--`.
#
# BOTH STEPS ARE EXTRACTED AND RUN, because asserting against
# `mk_pass_dir`'s own files proved nothing -- the file measured was this
# suite's, not the workflow's.
#
# HOISTING THE `chmod` ABOVE THE FIRST PASS'S COPY IS NOW HARMLESS, and
# that is the redirect's doing rather than this assertion's: `cat src >
# dst` creates `dst` under the umask whatever `src` is, so the order of
# the two statements stopped mattering. The assertion stays as a guard
# against a future explicit `chmod` on `prompt.md` itself, which is the
# only remaining way to make the first pass's prompt unwritable.
PROMPT_STEP="$WORK/create_prompt.sh"
extract_step "Create review prompt" > "$PROMPT_STEP"
check "the prompt-building step's shell was found in the workflow file" \
  '1' "$([ -s "$PROMPT_STEP" ] && echo 1 || echo 0)"
MODES=$(mk_pass_dir modes 25)
mkdir -p "$MODES/build-resources/claude"
printf 'INSTRUCTIONS\n\nBegin.\n' > "$MODES/build-resources/claude/pr-prompt-v2.md"
rm -f "$MODES/tmp/prompt-common.md" "$MODES/tmp/prompt.md"
printf 'the discussion goes here\n' > "$MODES/tmp/discussion.md"
( cd "$MODES" && RUNNER_TEMP="$MODES/tmp" HEAD_SHA=abc1234 REVIEW_FILES=45 \
    REVIEW_ADDITIONS=1 REVIEW_DELETIONS=1 \
    bash -eo pipefail "$PROMPT_STEP" > "$MODES/tmp/prompt_log.txt" 2>&1 ) || true
# shellcheck disable=SC2012  # the path is this suite's own, not a user's
check "the step makes the shared prefix read-only" \
  '-r--r--r--' "$(ls -l "$MODES/tmp/prompt-common.md" | cut -c1-10)"
# shellcheck disable=SC2012
check "and the first pass's prompt is still writable" \
  '1' "$(ls -l "$MODES/tmp/prompt.md" | cut -c1-10 | grep -c '^-.w')"
check "and it ends in Begin., so the step actually appended to it" \
  'Begin.' "$(tail -1 "$MODES/tmp/prompt.md")"

# THE SECOND PASS, CHAINED ONTO THAT REAL OUTPUT. Its prompt is built from
# a prefix the production step has already made read-only.
run_second_pass "$MODES" "$WORK/sp_good.jsonl" 0
# shellcheck disable=SC2012
check "the prompt the second pass appends to is writable" \
  '1' "$(ls -l "$MODES/tmp/prompt-2.md" | cut -c1-10 | grep -c '^-.w')"
# AND NOT A `SECOND_PASS_STATUS` ASSERTION BESIDE IT. These fixtures run as
# root, which may write a 444 file, so the step COMPLETES under the broken
# `cp` here while failing with Permission denied for the runner's uid 1001
# -- measured both ways. An outcome assertion would be green on the defect
# and read as a second guard; the mode is the only thing observable from
# this user, and it is what the line above tests.
check "the assignment comes after it, so the shared prefix is the longest one" \
  '1' "$(grep -c '^## Second pass' "$GOOD/tmp/prompt-2.md")"
check "and Begin. is still the last line" \
  'Begin.' "$(tail -1 "$GOOD/tmp/prompt-2.md")"
# ONCE, AND ONLY AT THE END. Copying the FIRST PASS'S FINISHED PROMPT instead
# of the shared prefix passes both assertions above -- the prefix is still
# shared and the file still ends in `Begin.` -- while stranding a `Begin.` in
# the middle, where the model is told to start reviewing before it has been
# given its assignment. Counting it is what tells the two apart, and this
# fixture did not until the mutation showed it passing over the defect.
check "and Begin. appears exactly once, not stranded mid-prompt" \
  '1' "$(grep -cx 'Begin\.' "$GOOD/tmp/prompt-2.md")"
# THE ORDERING THAT BUYS THE CACHE. The pull request's own comment thread is
# the largest block and it is shared between the two prompts, so it has to
# sit INSIDE the shared prefix with the per-invocation assignment after it.
# Put the assignment first and the two prompts share only the instruction
# file, which is the arrangement a reviewer flagged.
THREAD_LINE=$(grep -n 'the discussion goes here' "$GOOD/tmp/prompt-2.md" | head -1 | cut -d: -f1 || true)
BLOCK_LINE=$(grep -n '^## Second pass' "$GOOD/tmp/prompt-2.md" | head -1 | cut -d: -f1 || true)
# shellcheck disable=SC2016  # a literal shell fragment from the workflow
check "and nothing builds a prompt with cp, which copies the source's mode" \
  '0' "$(grep -v '^[[:space:]]*#' "$WORKFLOW_FILE" \
    | grep -c 'cp "\$RUNNER_TEMP/prompt' || true)"

check "the shared thread is in the prompt at all" \
  '1' "$([ -n "${THREAD_LINE:-}" ] && echo 1 || echo 0)"
check "and the assignment comes after it, not before" \
  '1' "$([ "${BLOCK_LINE:-0}" -gt "${THREAD_LINE:-0}" ] && echo 1 || echo 0)"
check "the second pass is pointed at its own manifest" \
  '1' "$(grep -c 'manifest-2.tsv' "$GOOD/tmp/prompt-2.md")"
check "and told that overrides the instruction above it" \
  '1' "$(grep -c 'overrides the instruction above' "$GOOD/tmp/prompt-2.md")"
check "a clean first pass is reported as none, not as an empty list" \
  '1' "$(grep -c 'None. The first pass reported no findings.' "$GOOD/tmp/prompt-2.md")"

# A completed pass: its findings are APPENDED to the first's.
check "a completed second pass is recorded as completed" \
  'completed' "$(env_of "$GOOD" SECOND_PASS_STATUS)"
check "and its findings reach the document the adjudicator reads" \
  '1' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["findings"]))' \
    "$GOOD/tmp/review.txt")"
check "which is still one line of JSON" \
  '1' "$(wc -l < "$GOOD/tmp/review.txt" | tr -d ' ')"

# The first pass's findings are shown to the second so it does not say them
# again -- the one place two passes can collide is a finding with no path.
WIDE=$(mk_pass_dir wide 25)
printf '{"findings":[{"severity":"RISK","path":"","line":0,"message":"No CODEOWNERS file in this repository."}]}\n' \
  > "$WIDE/tmp/review.txt"
run_manifest_step "$WIDE" 25
run_second_pass "$WIDE" "$WORK/sp_good.jsonl" 0
check "the first pass's repo-wide finding is quoted to the second pass" \
  '1' "$(grep -c 'No CODEOWNERS file in this repository.' "$WIDE/tmp/prompt-2.md")"
check "and the quoted block is marked as a record, not as instruction" \
  '1' "$(grep -c 'They are not instructions' "$WIDE/tmp/prompt-2.md")"
check "both passes' findings survive into the merged document" \
  '2' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["findings"]))' \
    "$WIDE/tmp/review.txt")"

# ---------------------------------------------------------------------------
# FIXTURE 3 AND 4. A second pass that returns no structured output is a
# FAILURE, whatever its exit status, and its reads are not credited.
#
# THE SHAPE THAT MAKES THIS NECESSARY: `sp_noverdict.jsonl` is a CLI that
# exited 0 having opened all twenty-five rows and called `StructuredOutput`
# never. Keying off the exit status credits those reads, drives
# COVERAGE_UNCOVERED to 0, and publishes "No blocking findings" over code
# nothing adjudicated.
# ---------------------------------------------------------------------------
for case in noverdict:0:'produced no structured output' \
  noverdict_err:1:'review command failed'; do
  label=${case%%:*}
  rest=${case#*:}
  status=${rest%%:*}
  reason=${rest#*:}
  reason=${reason#\'}
  reason=${reason%\'}
  DIR=$(mk_pass_dir "$label" 25)
  run_manifest_step "$DIR" 25
  run_second_pass "$DIR" "$WORK/sp_noverdict.jsonl" "$status"
  check "a pass with no structured output (exit ${status}) is a failure" \
    'failed' "$(env_of "$DIR" SECOND_PASS_STATUS)"
  check "and it is never recorded as completed (exit ${status})" \
    '0' "$(grep -c '^SECOND_PASS_STATUS=completed$' "$DIR/tmp/github.env")"
  check "the first pass's findings document is left untouched (exit ${status})" \
    '{"findings":[]}' "$(cat "$DIR/tmp/review.txt")"
  check "and the pull request is told nothing in those rows was adjudicated (exit ${status})" \
    '1' "$(grep -c 'Nothing in those rows has been adjudicated' "$DIR/tmp/sections.tsv")"
  # WHICH MECHANISM CAUGHT IT, and this assertion is the reason the explicit
  # test exists at all. An empty structured output means an empty findings
  # file, and `review_text.py --merge` refuses one of those -- so deleting
  # the emptiness test leaves this step STILL failing, by the wrong route,
  # with a diagnosis about combining two documents and no transcript shape
  # in the log. The property survives; the ability to tell why does not,
  # and the next change to the merge removes the property with nothing
  # pointing at it. Asserting the REASON is what separates the two.
  check "and the reason names what actually happened (exit ${status})" \
    '1' "$(sed -n 's/^SECOND_PASS_ERROR=//p' "$DIR/tmp/github.env" | tail -1 \
      | grep -cF "$reason")"
  # THE `fail_` HALF OF THE SPLIT, which nothing pinned: rewriting all
  # three designed invocation-failure paths to `skip_second_pass` left the
  # whole suite green, so every genuine failure could have told the pull
  # request no call was made and no spend occurred.
  check "a pass that was invoked says so (exit ${status})" \
    '1' "$(grep -c 'handed to a second reviewer invocation' \
      "$DIR/tmp/sections.tsv")"
  check "and does not claim it was skipped (exit ${status})" \
    '0' "$(grep -c 'were not re-reviewed' "$DIR/tmp/sections.tsv")"
  # THE JOB LOG TOO. Lower severity than the comment -- nobody reads it
  # unless they are diagnosing -- but it is one of the things this round
  # claims to have split, and three mutations of the phrase survived.
  check "and the job log says the pass did not complete (exit ${status})" \
    '1' "$(grep -c '::warning::the second review pass did not complete' \
      "$DIR/tmp/run_log.txt")"
  check "and not that no pass was made (exit ${status})" \
    '0' "$(grep -c 'no second review pass was made' "$DIR/tmp/run_log.txt")"
done

# AN UNDESIGNED FAILURE SAYS WHAT A DESIGNED ONE SAYS. `continue-on-error`
# keeps the first pass's review publishable, and on its own that is all it
# does: the reader gets a normal review with no trace that a second pass was
# attempted and died. The ERR trap is what puts it on the comment, and it
# covers the whole step -- including the one statement between the merge and
# the status write, where a death would otherwise publish both passes'
# findings beside a section naming the files the second pass just reviewed.
#
# THE INJECTED FAILURE IS A MISSING FILE in the unguarded region: the
# redirect that copies the shared prefix, which no `if` wraps. Every DESIGNED failure routes
# through `fail_second_pass` and exits 0, so none of them can exercise this.
TRAPPED=$(mk_pass_dir trapped 25)
run_manifest_step "$TRAPPED" 25
rm -f "$TRAPPED/tmp/prompt-common.md"
run_second_pass "$TRAPPED" "$WORK/sp_good.jsonl" 0
check "an uncaught failure is recorded as a failed second pass" \
  'failed' "$(env_of "$TRAPPED" SECOND_PASS_STATUS)"
check "and it is never recorded as completed" \
  '0' "$(grep -c '^SECOND_PASS_STATUS=completed$' "$TRAPPED/tmp/github.env")"
check "and the pull request is told the rows were not re-reviewed" \
  '1' "$(grep -c 'were not re-reviewed (the second-pass step did not finish' \
    "$TRAPPED/tmp/sections.tsv")"
# AND CLAIMS NO CALL, because this failure is injected in the prompt
# assembly -- before any `claude -p` exists. The trap covers both sides of
# the invocation and more lines before it than after, so a trap fixed at
# `fail_` would reinstate there the claim the three designed paths were
# just corrected for.
check "and claims no invocation on a failure that preceded one" \
  '0' "$(grep -c 'handed to a second reviewer invocation' \
    "$TRAPPED/tmp/sections.tsv")"
check "and no transcript was produced, which is what makes that true" \
  '0' "$([ -e "$TRAPPED/tmp/stream-2.jsonl" ] && echo 1 || echo 0)"
check "and the first pass's findings are left intact to publish" \
  '{"findings":[]}' "$(cat "$TRAPPED/tmp/review.txt")"

# THE OTHER SIDE OF THE SAME TRAP. An uncaught failure AFTER the call must
# still say a call was made. Injected at the unguarded recovery redirect by
# making its destination a directory, which no `if` wraps and which is the
# first bare command after `run_review` returns.
TRAPPED_LATE=$(mk_pass_dir trapped_late 25)
run_manifest_step "$TRAPPED_LATE" 25
mkdir -p "$TRAPPED_LATE/tmp/review-2.json"
run_second_pass "$TRAPPED_LATE" "$WORK/sp_good.jsonl" 0
check "an uncaught failure after the call is still a failed second pass" \
  'failed' "$(env_of "$TRAPPED_LATE" SECOND_PASS_STATUS)"
check "and says the rows were handed to an invocation" \
  '1' "$(grep -c 'handed to a second reviewer invocation' \
    "$TRAPPED_LATE/tmp/sections.tsv")"
check "and does not claim they were skipped" \
  '0' "$(grep -c 'were not re-reviewed' "$TRAPPED_LATE/tmp/sections.tsv")"
check "and a transcript exists, which is what makes that true" \
  '1' "$([ -e "$TRAPPED_LATE/tmp/stream-2.jsonl" ] && echo 1 || echo 0)"

# THE THIRD INVOCATION-FAILURE SITE: the merge. A transcript whose
# `structured_output` is an object with no `findings` array survives the
# emptiness test -- `review_text.py` recovers it, and it is not blank -- so
# it reaches `--merge`, which refuses it. Nothing pinned this branch, and
# two mutations of it survived: turning its `fail_` into a `skip_`, and
# deleting its `exit 0`, which falls through to `mv` over the empty file
# the failed redirect created and then writes `completed` -- a zero-byte
# findings document with the gate saying every read is credited.
{
  sp_reads
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"notfindings":[]}}'
} > "$WORK/sp_badshape.jsonl"
BADSHAPE=$(mk_pass_dir badshape 25)
run_manifest_step "$BADSHAPE" 25
run_second_pass "$BADSHAPE" "$WORK/sp_badshape.jsonl" 0
check "a second pass whose output is not a findings document is a failure" \
  'failed' "$(env_of "$BADSHAPE" SECOND_PASS_STATUS)"
check "and is never recorded as completed" \
  '0' "$(grep -c '^SECOND_PASS_STATUS=completed$' "$BADSHAPE/tmp/github.env")"
check "and the reason names the merge, not the structured output" \
  '1' "$(sed -n 's/^SECOND_PASS_ERROR=//p' "$BADSHAPE/tmp/github.env" | tail -1 \
    | grep -c 'could not be combined')"
check "and the pull request is told a call was made" \
  '1' "$(grep -c 'handed to a second reviewer invocation' \
    "$BADSHAPE/tmp/sections.tsv")"
check "and does not claim it was skipped" \
  '0' "$(grep -c 'were not re-reviewed' "$BADSHAPE/tmp/sections.tsv")"
# THE `exit 0` IS WHAT STOPS THE FALL-THROUGH. Without it the first pass's
# findings are replaced by the empty file the refused merge left behind.
check "and the first pass's findings document is intact, not emptied" \
  '{"findings":[]}' "$(cat "$BADSHAPE/tmp/review.txt")"

# THE GATE, READ OFF THE WORKFLOW. The re-measurement is what would credit
# those reads, and it runs only on `completed`. Asserted on the file because
# `extract_step` runs a step's shell and never its `if:`.
check "the both-passes coverage step runs only on a completed second pass" \
  '1' "$(grep -cF "env.SECOND_PASS_STATUS == 'completed'" "$WORKFLOW_FILE")"
# AND IT IS THE ONLY CONDITION ON THAT STEP. A gate that ALSO accepted the
# row count -- the variable the previous step sets before anything has run --
# would be the same step with the safety property removed, and it would still
# pass every assertion above.
check "the both-passes coverage step's condition names nothing weaker" \
  "env.REVIEW_OUTCOME == 'reviewed' && env.SECOND_PASS_STATUS == 'completed'" \
  "$(extract_step_if "Measure coverage across both passes")"

# WHY THAT GATE IS NOT DECORATION. Run the re-measurement over the same
# dangerous transcript and it reports full coverage -- which is exactly what
# the gate stops reaching the comment.
NOGATE=$(mk_pass_dir nogate 25)
run_manifest_step "$NOGATE" 25
cat "$WORK/sp_noverdict.jsonl" > "$NOGATE/tmp/stream-2.jsonl"
: > "$NOGATE/tmp/stream.jsonl"
run_measure_both() { # run_measure_both <dir>
  ( cd "$1" && RUNNER_TEMP="$1/tmp" GITHUB_ENV="$1/tmp/github.env" \
      GITHUB_WORKSPACE="$WS" SECOND_PASS_ROWS=25 COVERAGE_READ=20 \
      bash -eo pipefail "$SECOND_MEASURE_STEP" > "$1/tmp/measure_log.txt" 2>&1 ) || true
}
run_measure_both "$NOGATE"
check "an ungated re-measurement would credit reads nothing adjudicated" \
  '25' "$(env_of "$NOGATE" COVERAGE_READ)"

# ---------------------------------------------------------------------------
# FIXTURE 5. The second pass's transcript is measured into the coverage total,
# against the ORIGINAL manifest, and the stale disclosure is replaced.
# ---------------------------------------------------------------------------
MEASURED=$(mk_pass_dir measured 25)
run_manifest_step "$MEASURED" 25
# The first pass opened rows 1-20; the second opened 21-45.
{
  local_i=1
  while [ "$local_i" -le 20 ]; do
    sp_call "a$local_i" "$WS/pr-files/$(printf '%04d' "$local_i").patch"
    sp_result "a$local_i"
    local_i=$((local_i + 1))
  done
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"findings":[]}}\n'
} > "$MEASURED/tmp/stream.jsonl"
cat "$WORK/sp_good.jsonl" > "$MEASURED/tmp/stream-2.jsonl"
run_measure_both "$MEASURED"
check "coverage is re-measured across both transcripts" \
  '45' "$(env_of "$MEASURED" COVERAGE_READ)"
check "against the whole change, not the second pass's own manifest" \
  '45' "$(env_of "$MEASURED" COVERAGE_TOTAL)"
check "and nothing is left uncovered" \
  '0' "$(env_of "$MEASURED" COVERAGE_UNCOVERED)"
check "the marker's pass fields are written for the adjudicator" \
  '2' "$(env_of "$MEASURED" COVERAGE_PASSES)"
check "including what the first pass alone had opened" \
  '20' "$(env_of "$MEASURED" COVERAGE_FIRST_READ)"
# AND THE ADJUDICATOR IS ACTUALLY GIVEN THEM. Both halves either side of
# this are pinned -- the step writes the two variables, and
# review_output.py renders them into a v5 marker -- while the wire between
# was not: deleting the two flags from the invocation leaves the suite
# green and publishes a v4 marker over a run that merged both passes,
# which is the thing the step above exists to prevent.
# shellcheck disable=SC2016  # literal shell fragments from the workflow
check "the adjudicator is passed the pass count" \
  '1' "$(extract_step "Adjudicate the review and build the comment" \
    | grep -c -- '--coverage-passes "\${COVERAGE_PASSES:-}"')"
# shellcheck disable=SC2016
check "and the first pass's own figure" \
  '1' "$(extract_step "Adjudicate the review and build the comment" \
    | grep -c -- '--coverage-first-read "\${COVERAGE_FIRST_READ:-}"')"

# THE STALE DISCLOSURE. The first measurement left a section naming 20 of 45
# and the rows it missed; those rows are open now. Two sections disagreeing
# with each other is worse than either.
check "the first pass's unopened-files section is replaced, not joined" \
  '0' "$(grep -c '^Files the reviewer did not open' "$MEASURED/tmp/sections.tsv")"
check "and the one on the comment is this run's, not the first pass's" \
  '0' "$(grep -c '20 of 45 openable opened' "$MEASURED/tmp/sections.tsv")"
check "the other sections are untouched" \
  '1' "$(grep -c '^Not reviewed' "$MEASURED/tmp/sections.tsv")"
check "and the comment says a second pass was needed and what it bought" \
  '1' "$(grep -c '^Second review pass	25 row(s) the first pass did not open were re-reviewed; 45 of 45 openable row(s) are now opened, against 20 after the first pass alone.$' \
    "$MEASURED/tmp/sections.tsv")"

# A second pass that opened only SOME of its rows is still a shortfall, and
# the comment has to name what is left rather than report the pass as done.
PARTIAL2=$(mk_pass_dir partial2 25)
run_manifest_step "$PARTIAL2" 25
: > "$PARTIAL2/tmp/stream.jsonl"
{
  sp_call p21 "$WS/pr-files/0021.patch"
  sp_result p21
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"findings":[]}}\n'
} > "$PARTIAL2/tmp/stream-2.jsonl"
run_measure_both "$PARTIAL2"
check "a second pass that opened one row of twenty-five is reported as such" \
  '1' "$(env_of "$PARTIAL2" COVERAGE_READ)"
check "and the remaining rows are named on the pull request again" \
  '1' "$(grep -c '^Files the reviewer did not open (1 of 45 openable opened)' \
    "$PARTIAL2/tmp/sections.tsv")"
check "and the gate still has a non-zero count to act on" \
  '44' "$(env_of "$PARTIAL2" COVERAGE_UNCOVERED)"

# ---------------------------------------------------------------------------
# THE JOB'S OWN BOUND NOW COVERS TWO MODEL CALLS
# ---------------------------------------------------------------------------
#
# `timeout-minutes` ends the job by CANCELLING it, and a cancelled job posts
# the cancellation notice and NOT the review -- `Post the review comment` is
# gated on `REVIEW_OUTCOME == 'reviewed'` with no `always()`, and it runs
# AFTER the second pass. So a second pass that runs past the job bound does
# not cost its own output, it costs the FIRST pass's, which was complete in
# $RUNNER_TEMP and never published.
#
# A fixed ten-minute bound on the second pass was the first answer and it was
# wrong: it is safe only if the first pass plus the preamble reliably finish
# inside twenty minutes, which nothing asserts -- the job bound is itself
# documented as unmeasured and the first pass is not bounded at all. Nor does
# the comforting correlation hold: a pass that spent twenty-two minutes
# grepping inside twenty files is exactly the shape that leaves twenty-five
# rows unopened AND takes a long time.

# THE TWO COPIES OF THE NUMBER MUST AGREE. `timeout-minutes` takes no `env`
# context, so the figure is written twice; both are read off the file here
# rather than restated, because a count a human has to maintain is a latent
# defect and this one decides whether a review gets published.

# AND IT IS STAMPED IN THE FIRST STEP, so everything the bound covers is
# inside the measurement -- the checkouts, the CLI install and the first pass
# included. Stamped later, the second pass would believe it had more room
# than the job does.
FIRST_STEP_NAME=$(grep -m1 '^      - name: ' "$WORKFLOW_FILE" | sed 's/^      - name: //')
# shellcheck disable=SC2016  # a literal shell fragment from the workflow
check "the job's start time is stamped in the job's FIRST step" \
  '1' "$(extract_step "$FIRST_STEP_NAME" | grep -c '^echo "JOB_STARTED_AT=\$(date +%s)" >> "\$GITHUB_ENV"$')"

# run_budget <case> <seconds already elapsed> -> the recorded status, or ""
# Runs the real second-pass step with the clock wound back.
run_budget() {
  local dir="$WORK/bud_$1"
  mkdir -p "$dir"
  cp -r "$WORK/sp_good/." "$dir/"
  : > "$dir/tmp/github.env"
  printf '{"findings":[]}\n' > "$dir/tmp/review.txt"
  # THE DONOR DIRECTORY ALREADY RAN A SECOND PASS, so its transcript is
  # copied in with everything else. Removed here, or "no second transcript
  # was produced" below would be asserting the donor's file rather than
  # this run's behaviour -- a fixture passing for the wrong reason.
  rm -f "$dir/tmp/stream-2.jsonl" "$dir/tmp/prompt-2.md"
  stub_runner "$dir"
  ( cd "$dir" && RUNNER_TEMP="$dir/tmp" GITHUB_ENV="$dir/tmp/github.env" \
      SECOND_PASS_ROWS=25 COVERAGE_READ=20 COVERAGE_TOTAL=45 \
      JOB_TIMEOUT_MINUTES="$JOB_TIMEOUT_ENV" \
      JOB_STARTED_AT=$(( $(date +%s) - $2 )) \
      STUB_TRANSCRIPT="$WORK/sp_good.jsonl" STUB_STATUS=0 \
      bash -eo pipefail "$SECOND_RUN_STEP" > "$dir/tmp/budget_log.txt" 2>&1 ) || true
  sed -n 's/^SECOND_PASS_STATUS=//p' "$dir/tmp/github.env" | tail -1
}

# Plenty of room: a first pass of two minutes inside a thirty-minute job.
check "a second pass with room to run still runs" \
  'completed' "$(run_budget roomy 120)"
check "and is bounded by its own ceiling rather than the whole job" \
  '1' "$(grep -c 'second pass bounded at 600s' "$WORK/bud_roomy/tmp/budget_log.txt")"

# THE CASE THAT LOSES A REVIEW. A first pass of twenty-two minutes inside a
# thirty-minute job: six minutes of job left, which a ten-minute bound would
# have spent, cancelling the job over a complete first-pass review.
check "a second pass with less room than it needs is bounded, not fixed at 10m" \
  'completed' "$(run_budget tight $(( JOB_TIMEOUT_ENV * 60 - 400 )))"
# A RANGE, NOT A POINT. The step reads its own clock a moment after this
# fixture set JOB_STARTED_AT, so one second of scheduling delay on a loaded
# runner moves the figure -- an exact 220 would be a test that fails for
# reasons that have nothing to do with the code. What matters is that the
# bound came from the remaining time rather than from a constant: it has to
# be near 220 and nowhere near the 600 ceiling.
TIGHT_BOUND=$(sed -n 's/^second pass bounded at \([0-9]*\)s$/\1/p' \
  "$WORK/bud_tight/tmp/budget_log.txt")
check "the tight run printed a bound at all" \
  '1' "$([ -n "$TIGHT_BOUND" ] && echo 1 || echo 0)"
check "and takes what the job has left, less the posting margin" \
  '1' "$([ "${TIGHT_BOUND:-0}" -ge 210 ] && [ "${TIGHT_BOUND:-0}" -le 225 ] \
    && echo 1 || echo 0)"

# NO ROOM AT ALL: skip, and publish what the first pass produced.
check "a second pass with no room is skipped, not started" \
  'failed' "$(run_budget starved $(( JOB_TIMEOUT_ENV * 60 - 200 )))"
# A SKIP IS NOT AN INVOCATION, and the comment that reaches the pull
# request has to say which happened. Three paths run before any
# `claude -p` exists and the budget skip is the common one -- "were handed
# to a second reviewer invocation" is false of all three, and this
# fixture's own name says "skipped, not started".
check "a skipped pass says the rows were not re-reviewed" \
  '1' "$(grep -c 'row(s) the first pass did not open were not re-reviewed' \
    "$WORK/bud_starved/tmp/sections.tsv")"
check "and claims no invocation that never happened" \
  '0' "$(grep -c 'handed to a second reviewer invocation' \
    "$WORK/bud_starved/tmp/sections.tsv")"
check "a skipped pass says in the log that no pass was made" \
  '1' "$(grep -c '::warning::no second review pass was made' \
    "$WORK/bud_starved/tmp/budget_log.txt")"
check "and not that one did not complete" \
  '0' "$(grep -c 'the second review pass did not complete' \
    "$WORK/bud_starved/tmp/budget_log.txt")"
check "and the reason names the job's bound rather than the reviewer" \
  '1' "$(sed -n 's/^SECOND_PASS_ERROR=//p' "$WORK/bud_starved/tmp/github.env" | tail -1 \
    | grep -c "of the job's ${JOB_TIMEOUT_ENV}-minute bound remained")"
check "and the first pass's findings document is untouched, ready to post" \
  '{"findings":[]}' "$(cat "$WORK/bud_starved/tmp/review.txt")"
check "and no second transcript was produced, so nothing new is credited" \
  '0' "$([ -e "$WORK/bud_starved/tmp/stream-2.jsonl" ] && echo 1 || echo 0)"

# AN UNRECORDED START TIME IS NOT "PLENTY OF TIME". The step cannot compute
# what is left, so it skips -- the direction that publishes the review it
# already has.
NOSTAMP="$WORK/bud_nostamp"
mkdir -p "$NOSTAMP"; cp -r "$WORK/sp_good/." "$NOSTAMP/"
: > "$NOSTAMP/tmp/github.env"
printf '{"findings":[]}\n' > "$NOSTAMP/tmp/review.txt"
stub_runner "$NOSTAMP"
( cd "$NOSTAMP" && RUNNER_TEMP="$NOSTAMP/tmp" GITHUB_ENV="$NOSTAMP/tmp/github.env" \
    SECOND_PASS_ROWS=25 COVERAGE_READ=20 COVERAGE_TOTAL=45 \
    STUB_TRANSCRIPT="$WORK/sp_good.jsonl" STUB_STATUS=0 \
    bash -eo pipefail "$SECOND_RUN_STEP" > "$NOSTAMP/tmp/log.txt" 2>&1 ) || true
check "an unrecorded start time skips the second pass rather than guessing" \
  'failed' "$(sed -n 's/^SECOND_PASS_STATUS=//p' "$NOSTAMP/tmp/github.env" | tail -1)"
# AND IT IS THE STAMP CHECK THAT CAUGHT IT, not the arithmetic behind it.
# This step runs without `set -u`, so an unset JOB_STARTED_AT evaluates to
# zero, ELAPSED becomes the whole epoch and the floor test fails anyway --
# the right outcome by the wrong route, diagnosed as "the job ran out of
# time" over a job that had just started. Asserting the REASON is what
# separates the two, and without it deleting the stamp check looks fine.
check "and the reason names the missing stamp, not an exhausted budget" \
  '1' "$(sed -n 's/^SECOND_PASS_ERROR=//p' "$NOSTAMP/tmp/github.env" | tail -1 \
    | grep -c "start time was not recorded")"

# THE BOUND HAS TO BE A HARD ONE. TERM is a REQUEST: measured,
# `timeout --signal=TERM 2` against a child that traps it returned 124 after
# THIRTY SECONDS, and a wedged CLI event loop does not service a signal
# either. Without a KILL behind it the arithmetic above is advisory.
check "the wall clock is enforced with a KILL behind the TERM" \
  '1' "$(grep -c -- 'timeout --kill-after=30s --signal=TERM' "$WORKFLOW_FILE")"
check "and no invocation is wrapped in a TERM-only timeout" \
  '0' "$(grep -v '^[[:space:]]*#' "$WORKFLOW_FILE" \
    | grep -c -- 'timeout --signal=TERM "' || true)"

# NOTHING AN UNTRUSTED MODEL HAS SHARED A RUNNER WITH STAYS WRITABLE. Three
# files: the two sourced helpers, and the shared prefix -- which is the
# strongest case of the three, being the second model's own prompt. The
# copy it is read into stays writable so the assignment can be appended.
# shellcheck disable=SC2016  # literal shell fragments from the workflow
check "the prompt every pass is built from is made read-only" \
  '1' "$(grep -c 'chmod 444 "\$RUNNER_TEMP/prompt-common.md"' "$WORKFLOW_FILE")"
# shellcheck disable=SC2016
check "the shared invocation file is made read-only before it is sourced" \
  '1' "$(grep -c 'chmod 444 "\$RUNNER_TEMP/run-review.sh"' "$WORKFLOW_FILE")"
# shellcheck disable=SC2016
CHMOD_LINE=$(grep -n 'chmod 444 "\$RUNNER_TEMP/run-review.sh"' "$WORKFLOW_FILE" | head -1 | cut -d: -f1 || true)
# shellcheck disable=SC2016
SOURCE_LINE=$(grep -n '^          \. "\$RUNNER_TEMP/run-review.sh"$' "$WORKFLOW_FILE" | head -1 | cut -d: -f1 || true)
# THE OTHER SOURCED FILE, and the sharper case of the same argument: every
# posting step sources it after the model has had its turn with Bash, and
# it is the one holding `gh api --method POST` against a token with
# `pull-requests: write`.
# shellcheck disable=SC2016  # a literal shell fragment from the workflow
check "the shared publish helper is made read-only too" \
  '1' "$(grep -c 'chmod 444 "\$RUNNER_TEMP/publish-comment.sh"' "$WORKFLOW_FILE")"
# THE MODE BITS, NOT `[ -w ]`. These fixtures run as root in CI and in the
# sandbox, and root may write a 444 file -- so `! -w` is false for a
# correctly hardened file and the assertion could only ever fail. `ls -l`
# reports what was actually set, and its first ten characters are the same
# on every POSIX system.
# shellcheck disable=SC2012  # the path is this suite's own, not a user's
check "and the file the step wrote carries no write bit at all" \
  '-r--r--r--' "$(ls -l "$WORK/bl_three/publish-comment.sh" | cut -c1-10)"

check "and it is made read-only BEFORE the first source, not after" \
  '1' "$([ "${CHMOD_LINE:-0}" -gt 0 ] && [ "${CHMOD_LINE:-0}" -lt "${SOURCE_LINE:-0}" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# CONCATENATING THE TRANSCRIPTS MUST NOT WELD TWO RECORDS INTO ONE
# ---------------------------------------------------------------------------
#
# These are newline-delimited JSON and `cat` concatenates BYTES. Where the
# first file's last line carries no trailing newline -- a killed writer, a
# buffer that did not flush -- the first pass's last record and the second
# pass's first become one line that parses as neither, and `json_lines`
# yields None for both. It fails toward "not reviewed": a COMPLETE two-pass
# review reports as a shortfall and goes red in a `fail` repository.
WELD=$(mk_pass_dir weld 25)
run_manifest_step "$WELD" 25
{
  sp_call w1 "$WS/pr-files/0001.patch"
  sp_result w1
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"findings":[]}}'
} > "$WELD/tmp/stream.jsonl"
# `od`, NOT `tr`. The earlier form piped the last byte through
# `tr -d '\n' | tr -d '}'` and compared the result to the empty string,
# which is empty for `}` AND for a newline -- so the assertion could not
# fail and the fixture below it would have gone on testing a terminated
# file. The byte itself is what has to be compared.
check "the first transcript genuinely ends without a newline" \
  '7d' "$(tail -c 1 "$WELD/tmp/stream.jsonl" | od -An -tx1 | tr -d ' \n')"
cat "$WORK/sp_good.jsonl" > "$WELD/tmp/stream-2.jsonl"
run_measure_both "$WELD"
check "an unterminated first transcript still credits both passes' reads" \
  '26' "$(env_of "$WELD" COVERAGE_READ)"
check "and nothing is reported as a shortfall that was in fact reviewed" \
  '19' "$(env_of "$WELD" COVERAGE_UNCOVERED)"

# THE DEGRADED BRANCH HAS TO DROP IT TOO. When the re-measurement itself
# cannot run, the comment says "coverage could not be measured across the
# two review passes" -- and the first pass's row, left standing, names a
# precise count and file list from a measurement of ONE pass, beside
# findings the OTHER pass produced. The removal therefore sits above the
# branch rather than inside the successful one. A corrupt manifest is what
# makes review_coverage.py exit non-zero.
DEGRADED=$(mk_pass_dir degraded 25)
run_manifest_step "$DEGRADED" 25
: > "$DEGRADED/tmp/stream.jsonl"
cat "$WORK/sp_good.jsonl" > "$DEGRADED/tmp/stream-2.jsonl"
printf 'only	two
' > "$DEGRADED/pr-files/manifest.tsv"
run_measure_both "$DEGRADED"
check "a re-measurement that could not run says so on the comment" \
  '1' "$(grep -c 'could not be measured across the two review passes' \
    "$DEGRADED/tmp/sections.tsv")"
check "and does not leave the first pass's file list standing beside it" \
  '0' "$(grep -c '^Files the reviewer did not open' "$DEGRADED/tmp/sections.tsv")"
check "and withholds the counts rather than keeping the first pass's" \
  'unmeasured' "$(env_of "$DEGRADED" COVERAGE_READ)"

# ---------------------------------------------------------------------------
# THE STEP SITS BETWEEN A FINISHED REVIEW AND ITS ONLY PUBLICATION
# ---------------------------------------------------------------------------
#
# Every DESIGNED failure in the second-pass step routes through
# `fail_second_pass` and exits 0. What `continue-on-error` covers is the
# rest of a two-hundred-line step running under `bash -e`: an uncaught
# non-zero skips the adjudication and the posting steps and fires the
# `failure()` notice, which tells the pull request the review could not run
# while a complete first-pass review sits in `$RUNNER_TEMP/review.txt`.
# ALL THREE OF THEM, not just the middle one. The step that builds the
# manifest would lose the FIRST pass's review by a route that did not exist
# before this change; the step that re-measures is worse, because by then
# `review.txt` holds BOTH passes' findings, so an uncaught non-zero spends
# two model invocations and publishes neither.
for step in "Build the second-pass manifest" "Run the second review pass" \
  "Measure coverage across both passes"; do
  check "the step cannot take the job down with it: ${step}" \
    '1' "$(awk -v want="      - name: ${step}" '
      $0 == want { instep = 1; next }
      instep && /^      - name: / { exit }
      instep { print }' "$WORKFLOW_FILE" \
      | grep -c '^        continue-on-error: true$')"
done
# AND NO OTHER STEP GAINS IT BY ACCIDENT. The posting steps and the two
# enforcement steps must still be able to fail the job.
# AND THE RE-MEASUREMENT WRITES ITS DEGRADED TOKENS ON ENTRY. From the
# moment the second pass has merged, the first pass's counts describe one
# transcript out of two; an uncaught death here would otherwise leave them
# standing and the gate would pass on a number that predates the second
# pass.
# THE FAILURE IS INJECTED AT THE FIRST THING THAT CAN FAIL, which is the
# concatenation: a missing `stream-2.jsonl` makes awk exit 2, `set -e` ends
# the step and `continue-on-error` swallows it. ~~Removing the manifest~~
# failed later, inside `review_coverage.py`, so it never exercised the
# window the entry write exists to close -- and the fixture passed anyway.
ENTRY=$(mk_pass_dir entry 25)
run_manifest_step "$ENTRY" 25
: > "$ENTRY/tmp/stream.jsonl"
rm -f "$ENTRY/tmp/stream-2.jsonl"
{
  printf 'COVERAGE_READ=20\nCOVERAGE_TOTAL=45\nCOVERAGE_UNCOVERED=25\n'
  printf 'COVERAGE_EXEMPT=0\n'
} > "$ENTRY/tmp/github.env"
run_measure_both "$ENTRY"
check "a re-measurement that dies leaves no stale count behind it" \
  'unmeasured' "$(env_of "$ENTRY" COVERAGE_UNCOVERED)"
check "and none of the other three survives either" \
  'unmeasured unmeasured unmeasured' \
  "$(printf '%s %s %s' "$(env_of "$ENTRY" COVERAGE_READ)" \
    "$(env_of "$ENTRY" COVERAGE_TOTAL)" "$(env_of "$ENTRY" COVERAGE_EXEMPT)")"
check "and the gate has no number it could pass on" \
  '0' "$(sed -n 's/^COVERAGE_UNCOVERED=//p' "$ENTRY/tmp/github.env" \
    | tail -1 | grep -c '^0$' || true)"
check "and the first pass's file list is not left naming reviewed rows" \
  '0' "$(grep -c '^Files the reviewer did not open' "$ENTRY/tmp/sections.tsv")"
# A RUN THAT MADE TWO PASSES MUST NOT PUBLISH A ONE-PASS MARKER. By here
# both sets of findings are merged into the comment, so `v4` would be a
# claim about the field set that the run contradicts.
check "and the marker still records that two passes ran" \
  '2' "$(env_of "$ENTRY" COVERAGE_PASSES)"
check "with the first pass's own figure beside it" \
  '20' "$(env_of "$ENTRY" COVERAGE_FIRST_READ)"

# EVERY STEP THAT IS NOT ONE OF THE THREE, checked by name rather than by
# a range. ~~The range form ended at `/^      - name: $/`~~, which no line
# can match -- so it ran to EOF and gave the right answer for the wrong
# reason, which is precisely what this file exists to catch in other
# people's code.
NOT_EXEMPT=""
while IFS= read -r step; do
  case "$step" in
    "Build the second-pass manifest" | "Run the second review pass" \
      | "Measure coverage across both passes") continue ;;
    # PRE-DATES THE SECOND PASS and is deliberate: a clone failure arrives
    # at "Verify build resources checkout" as an empty HEAD rather than a
    # red step, which is where it becomes a comment instead of a job that
    # posts nothing. Found by replacing the range form above -- it had been
    # running to EOF and counting this one as zero.
    "Checkout build resources") continue ;;
  esac
  if awk -v want="      - name: $step" '
      $0 == want { instep = 1; next }
      instep && /^      - name: / { exit }
      instep { print }' "$WORKFLOW_FILE" \
      | grep -q '^        continue-on-error: true$'; then
    NOT_EXEMPT="$NOT_EXEMPT [$step]"
  fi
done < <(sed -n 's/^      - name: //p' "$WORKFLOW_FILE")
check "and no other step is allowed to swallow its own failure" \
  '' "$NOT_EXEMPT"

# ---------------------------------------------------------------------------
# THE MEASUREMENT IS INVOKED TWICE AND THE TWO CALLS MUST NOT DRIFT
# ---------------------------------------------------------------------------
#
# The both-passes call is a hand copy of the first one, and the argument
# written beside `run-review.sh` -- that a copied invocation is how a
# `--safe-mode` goes missing from one of them -- applies to it unchanged.
# It was applied to the model call and not to the measurement call
# duplicated in the same change.
#
# THE TWO SILENT LOSSES, both in the reassuring direction. Without
# `--restored`, rows the workflow reverted to base content stop being
# exempt and count as uncovered -- so a COMPLETE two-pass review goes red
# in a `fail` repository over rows the prompt forbids opening, which
# review_coverage.py's own docstring says the author cannot clear. Without
# `--workspace`, `workspace_split` takes the empty-prefix branch and
# `opened()` degrades to the suffix test, which that docstring names as the
# defect that credits a row for a vendored copy of a different file.
# Deleting either from the new call left this whole suite green.
#
# COMPARED AS ARGUMENT LISTS, not asserted flag by flag: a list of flags
# here would be a third copy, free to go stale in the same way.
# shellcheck disable=SC2016  # literal shell fragments from the workflow
coverage_call() { # coverage_call <step name> -> its review_coverage.py argv
  extract_step "$1" \
    | awk '
        /python3 build-resources\/claude\/review_coverage\.py/ { incall = 1 }
        incall {
          printf "%s ", $0
          if ($0 !~ /\\$/) { print ""; exit }
        }' \
    | sed -e 's/\\//g' \
          -e 's/^[[:space:]]*if //' \
          -e 's/; then[[:space:]]*$//' \
          -e 's|> *"\$RUNNER_TEMP/coverage[^"]*"||' \
          -e 's|--uncovered-file *"\$RUNNER_TEMP/uncovered\.txt"||' \
          -e 's|"\$RUNNER_TEMP/stream[^"]*"||' \
          -e 's/[[:space:]][[:space:]]*/ /g' \
          -e 's/^ //' -e 's/ $//'
}
FIRST_CALL=$(coverage_call "Measure review coverage")
BOTH_CALL=$(coverage_call "Measure coverage across both passes")
check "the first measurement's invocation was found" \
  '1' "$([ -n "$FIRST_CALL" ] && echo 1 || echo 0)"
check "and the both-passes one" \
  '1' "$([ -n "$BOTH_CALL" ] && echo 1 || echo 0)"
check "the two measurement calls differ only in what they are measuring" \
  "$FIRST_CALL" "$BOTH_CALL"
# AND THE COMPARISON IS NOT OF TWO BLANKS. The normalisation above strips
# three things; if it ever stripped everything, the assertion would pass
# over two empty strings -- the shape the byte-identity fixture guards
# against with `cksum`.
check "and the thing compared still names the flags that matter" \
  '1' "$(printf '%s\n' "$FIRST_CALL" \
    | grep -c -- '--workspace .* --github-env .* --missed-file .* --restored')"

# ---------------------------------------------------------------------------
# ONE INVOCATION, ONE DEFINITION
# ---------------------------------------------------------------------------
#
# The safety flags, the tool allow list and the deny list live in
# `run-review.sh` and both passes source it. A second `claude -p` command
# line in this file is how a `--safe-mode` goes missing from one of them:
# both still run, both still produce a review, and only one is protected.
# SCOPED TO THE JOB. The `workflow_call` inputs above it are prose for a
# consumer to read, and one of them names `claude -p --resume` while
# explaining why this design does not use it -- a sentence, not a second
# invocation. Everything that executes is under `jobs:`.
check "the CLI is invoked from exactly one place in the workflow" \
  '1' "$(sed -n '/^jobs:/,$p' "$WORKFLOW_FILE" | grep -c 'claude -p ')"
# shellcheck disable=SC2016  # a literal shell fragment from the workflow
check "and both passes reach it through the shared helper" \
  '2' "$(grep -c 'run_review "\$RUNNER_TEMP' "$WORKFLOW_FILE")"
check "the deny list is stated once, where both passes get it" \
  '1' "$(grep -c 'disallowedTools "WebFetch,WebSearch"' "$WORKFLOW_FILE")"
# Twice in the file, once as code: the other is the comment in "Neutralise
# reviewer configuration the PR controls" explaining why the flags are
# there. Comment lines are excluded, as they are in the self-pin assertions
# above, so prose about a flag is never read as a second use of it.
check "and so is the safe-mode pair" \
  '1' "$(grep -v '^[[:space:]]*#' "$WORKFLOW_FILE" \
    | grep -c -- '--safe-mode --setting-sources user')"

# THE SECOND PASS GETS ITS OWN WALL CLOCK, because the job's bound ends the
# job by CANCELLING it and a cancelled job posts no review at all -- so a
# hung second pass would cost the pull request the review it already had.
# shellcheck disable=SC2016  # a literal shell fragment from the workflow
check "the second pass is bounded by what the job has left" \
  '1' "$(grep -c 'review-2.err" "\$BUDGET"; then' "$WORKFLOW_FILE")"
check "and no fixed bound survives in the file" \
  '0' "$(grep -v '^[[:space:]]*#' "$WORKFLOW_FILE" | grep -c 'review-2.err" 10m' || true)"
# AND THE FIRST PASS IS NOT, so its invocation is the one this file has
# always made. The helper takes the bound as its fourth argument precisely so
# this is visible at each call site rather than in a variable set elsewhere.
# shellcheck disable=SC2016  # a literal shell fragment from the workflow
check "and the first pass passes no fourth argument" \
  '1' "$(grep -c '"\$RUNNER_TEMP/stream.jsonl" "\$RUNNER_TEMP/review.err"; then' \
    "$WORKFLOW_FILE")"

if [ "$FAILED" -ne 0 ]; then
  echo "review workflow tests FAILED" >&2
  exit 1
fi
echo "review workflow tests passed"
