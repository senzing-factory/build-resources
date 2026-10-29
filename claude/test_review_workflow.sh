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
#
# The override exists so the guard can be run against an OLDER revision of
# the workflow to prove an assertion fails there before it passes here.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORKFLOW_FILE="${WORKFLOW_FILE:-$HERE/../.github/workflows/claude-pull-request-review.yaml}"
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

if [ "$FAILED" -ne 0 ]; then
  echo "review workflow tests FAILED" >&2
  exit 1
fi
echo "review workflow tests passed"
