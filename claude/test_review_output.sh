#!/usr/bin/env bash
# cspell:ignore orun jrun deadbeefcafe realsha  -- fixture / local names
# Fixture tests for review_output.py. No framework: builds a small repository
# and a deliberately bad set of findings, runs the adjudicator, and checks
# what survived.
#
# WHAT THE INPUT IS NOW. `--findings` names a JSON document,
# `{"findings": [...]}`, recovered by review_text.py from the `structured_output`
# of the CLI's terminal `result` event and already validated against
# `claude/review-schema.json` by the CLI. There is no markdown contract and no
# prose parser: the severity is an enum, the path and the line are separate
# typed fields, and this program is the SECOND WITNESS to that validation
# rather than the thing performing it. Every fixture here is therefore a JSON
# document, and the shapes that used to be "malformed prose" are now either an
# object the schema refuses or text that conforms while being hostile.
#
# WHY THESE FIXTURES. The findings used here are not invented -- each is a
# shape this reviewer has actually produced on a pull request:
#
#   * a BLOCKING demand for a CHANGELOG in a repository that has none (38.4%
#     of this reviewer's historical blocking demands, measured across 4,932
#     reviews);
#   * a finding that is the reviewer reporting its own blindness (13 such
#     phrases per review in one measured pair);
#   * a line number past the end of the file it cites;
#   * the same finding reported twice;
#   * a finding whose own text says there is nothing to flag.
#
# The point of each assertion is that NONE of those reaches a pull request,
# and that each is counted so the rate stays visible. A mechanism with no
# count is a mechanism nobody can tell has stopped working.
#
# The second family is the opposite failure, and it is the worse one: a review
# that found a real problem landing as "No blocking findings." Four routes to
# it, each with its own block below -- a sole finding removed by a rejection
# rule with no record on the pull request; a rejection rule whose wording eats
# a real finding; a clean headline that says nothing about how little was
# opened; and a comment trimmed to its byte budget while its own header still
# counts what was trimmed away.
#
# The third family is MECHANISM 12, which the schema does not cover and cannot:
# text that conforms to the schema exactly while forging the comment's own
# structure. A newline in a message ends the bullet the body is assembled from;
# an HTML comment in a message forges the state marker `previous_stats` reads;
# a backtick in a path breaks the inline code span it is rendered into. Those
# are the `hostile text` block.
#
# Usage:  ./test_review_output.sh      # from anywhere; exits non-zero on failure
#
# SC2016 is disabled for the file, and only SC2016. A finding line's format is
# `- **BLOCKER** `path:line` - message`, so almost every pattern and fixture
# here contains backticks, which shellcheck reads as command substitution it is
# warning you will not happen. It will not happen, and that is the point: these
# are literal markdown under test. Dozens of inline directives for one reason
# read worse than one statement of the reason.
# shellcheck disable=SC2016
set -euo pipefail

# HERMETIC AGAINST THE ONE VARIABLE THAT CHANGES THE OUTPUT. `anchor` reads
# `GITHUB_REPOSITORY` to decide whether the commit renders as a link, and a
# GitHub runner sets it on every job while a developer's shell does not. Left
# inherited, four Mechanism 13 assertions pass locally and fail in CI against
# a correct program -- measured on this suite, 2026-10-29. The fixtures that
# want the link set it themselves; everything else must see it absent, so the
# absence is declared here rather than assumed.
unset GITHUB_REPOSITORY

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/review_output.py"
SCHEMA="$HERE/review-schema.json"
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

rep() { # rep <count> <char> -> that character, that many times
  head -c "$1" /dev/zero | tr '\000' "$2"
}

chars_in() { # chars_in <file> -> its length in characters, not bytes
  python3 -c 'import io,sys; print(len(io.open(sys.argv[1], encoding="utf-8").read()))' "$1"
}

# A repository whose BASE has README.md and src/auth.go but no CHANGELOG.md.
# The absence is the fixture: a CHANGELOG finding has nothing to cite.
REPO="$WORK/repo"
mkdir -p "$REPO/src"
(
  cd "$REPO"
  git init -q .
  git config user.email fixture@example.invalid
  git config user.name Fixture
  git config commit.gpgsign false
  printf '# readme\n' > README.md
  printf 'package main\n' > src/auth.go
  # Dotfiles at base, because `.github/workflows/*` is the most-reviewed file
  # class in this fleet.
  mkdir -p .github/workflows
  printf 'name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n' \
    > .github/workflows/ci.yaml
  printf '*.log\n' > .gitignore
  git add -A
  git commit -qm base
  git rev-parse HEAD > "$WORK/base.sha"
  # Forty lines, so line 12 resolves and line 9999 does not.
  for i in $(seq 1 40); do printf 'line %s\n' "$i" >> src/auth.go; done
  printf 'new\n' > src/new.go
  # The three files `line_count` has to tell apart. A terminator reading of
  # the newline makes these three different answers, and the old form gave
  # the same wrong one to all of them.
  printf 'a\nb\nc\n' > src/three.txt
  printf 'a\nb\nc' > src/notrail.txt
  : > src/empty.txt
  git add -A
  git commit -qm change
) > /dev/null
BASE=$(cat "$WORK/base.sha")

{
  printf 'modified\t41\tsrc/auth.go\tpr-files/0001.patch\n'
  printf 'added\t1\tsrc/new.go\tpr-files/0002.patch\n'
  printf 'modified\t0\tlogo.png\tbinary\n'
  printf 'modified\t3\tREADME.md\tpr-files/0003.patch\n'
} > "$REPO/manifest.tsv"

# A separate manifest for the `line_count` block, so those rows cannot move
# any count the main fixture asserts. `src/gone.go` is a row with no file:
# the reviewer cited a path the checkout does not hold.
{
  printf 'added\t3\tsrc/three.txt\tpr-files/0001.patch\n'
  printf 'added\t3\tsrc/notrail.txt\tpr-files/0002.patch\n'
  printf 'added\t0\tsrc/empty.txt\tpr-files/0003.patch\n'
  printf 'removed\t4\tsrc/gone.go\tpr-files/0004.patch\n'
} > "$REPO/lines.tsv"

printf 'Not reviewed (dropped by exclude_globs)\tyarn.lock\n' > "$REPO/sections.tsv"
printf 'Binary (no reviewable content)\t\n' >> "$REPO/sections.tsv"

printf 'the version table matches the new pin\n' > "$REPO/notes.txt"

jf() { # jf <name> <json text> -> writes the findings document
  printf '%s\n' "$2" > "$REPO/$1"
}

# The extra arguments go BEFORE the coverage defaults, because `_flag` takes
# the FIRST occurrence of a flag: a caller's `--coverage-read 3` has to be
# reached before the 4 this helper supplies, or the override is silently
# ignored and the fixture asserts a denominator it did not pass.
orun() { # orun <findings> <out> <metrics> [extra args...] -> stdout
  FINDINGS="$1"
  OUT="$2"
  METRICS="$3"
  shift 3
  ( cd "$REPO" && python3 "$SCRIPT" \
      --findings "$FINDINGS" --manifest manifest.tsv --base "$BASE" \
      --out "$OUT" --metrics "$METRICS" --head abc --lane B "$@" \
      --coverage-read 4 --coverage-total 4 )
}

metric_of() { # metric_of <file> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

echo "review_output.py"

# ---------------------------------------------------------------------------
# The central document: every content rule at once
# ---------------------------------------------------------------------------

jf main.json '{"findings":[
{"severity":"BLOCKER","path":"CHANGELOG.md","line":0,"message":"The missing CHANGELOG entry for this change hides it from the release notes. Add one."},
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"Unvalidated input reaches the query builder. Validate it."},
{"severity":"BLOCKER","path":"src/auth.go","line":9999,"message":"Possible nil dereference at the end of the file. Guard it."},
{"severity":"RISK","path":"logo.png","line":0,"message":"I cannot see the contents of this file, so I could not review it."},
{"severity":"BLOCKER","path":"README.md","line":0,"message":"The documented flag no longer exists in the code. Update the text."},
{"severity":"RISK","path":"docs/api.md","line":0,"message":"The API documentation was not updated. Update it."}
]}'

: > "$REPO/metrics.env"
LOG=$(orun main.json body.md metrics.env \
  --sections sections.tsv --notes notes.txt \
  --coverage-read 3 --coverage-total 4 --summary '4 files, +41/-0.')
BODY="$REPO/body.md"

# ---------------------------------------------------------------------------
# Mechanism 1 -- no output template
# ---------------------------------------------------------------------------
#
# There is no prose channel left to strip, so what this asserts now is the
# other half of mechanism 1: a disclosure section exists only when something
# populated it.

check "a populated section appears" \
  '1' "$(grep -c '^\*\*Not reviewed (dropped by exclude_globs)\*\*$' "$BODY")"
check "an empty section does not appear" \
  '0' "$(grep -c 'Binary (no reviewable content)' "$BODY" || true)"

# ---------------------------------------------------------------------------
# Mechanism 2 -- a missing convention must cite a path that exists at base
# ---------------------------------------------------------------------------

check "a CHANGELOG finding in a repo with no CHANGELOG is dropped" \
  '0' "$(grep -c 'CHANGELOG' "$BODY" || true)"
check "a doc finding citing a path that never existed is dropped" \
  '0' "$(grep -c 'docs/api.md' "$BODY" || true)"
check "both are counted as padding" \
  '2' "$(metric_of "$REPO/metrics.env" REVIEW_PADDING_REJECTED)"
check "the log says why, naming the citation" \
  '1' "$(printf '%s\n' "$LOG" | grep -c 'padding rejected (citation absent at base) CHANGELOG.md')"

# The gate is the citation, not the vocabulary. README.md exists at base, so
# a finding about it survives even though its wording would otherwise match.
check "a finding citing a path that does exist at base survives" \
  '1' "$(grep -c 'The documented flag no longer exists' "$BODY")"

# ---------------------------------------------------------------------------
# Mechanism 3 -- blindness is a coverage status, not a verdict
# ---------------------------------------------------------------------------

check "a blindness claim does not reach the comment" \
  '0' "$(grep -c 'cannot see the contents' "$BODY" || true)"
check "it is counted as rerouted" \
  '1' "$(metric_of "$REPO/metrics.env" REVIEW_BLIND_REROUTED)"
check "and it is logged with a reason code from the manifest row" \
  '1' "$(printf '%s\n' "$LOG" | grep -c 'blindness -> coverage \[BINARY\]')"

# ---------------------------------------------------------------------------
# Mechanism 4 -- an unresolvable anchor is downgraded, never promoted
# ---------------------------------------------------------------------------

check "a line past the end of the file loses its line number" \
  '0' "$(grep -c 'src/auth.go:9999' "$BODY" || true)"
check "and its severity drops to RISK" \
  '1' "$(grep -c '^- ⚠️ \*\*RISK\*\* `src/auth.go` — Possible nil dereference' "$BODY")"
check "a resolvable anchor keeps BLOCKER and its line" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/auth.go:12` — Unvalidated input' "$BODY")"
check "the downgrade is counted" \
  '1' "$(metric_of "$REPO/metrics.env" REVIEW_ANCHOR_DOWNGRADED)"

# ---------------------------------------------------------------------------
# Mechanism 5 -- the header and the marker are the program's, not the model's
# ---------------------------------------------------------------------------

check "the header counts what survived, not what was submitted" \
  '1' "$(grep -c '^\*\*3 findings in the 3 of 4 files opened\*\* — 2 blockers, 1 risk\.$' "$BODY")"
check "the marker is written from the measurement" \
  '1' "$(grep -c '^<!-- claude-review v3 lane=B findings=3 blockers=2 dropped=3 read=3/4 head=abc -->$' "$BODY")"
check "exactly one marker reaches the comment" \
  '1' "$(grep -c 'claude-review v3' "$BODY")"

# $GITHUB_ENV DISCIPLINE. Every metric is a number -- REVIEW_PREV_FINDINGS is
# -1 when there is no previous comment, hence the sign. A path or a line of
# the model's prose in that file is author-controlled text one newline away
# from appending arbitrary variables to the job environment.
check "the metrics file carries nothing but KEY=number lines" \
  '0' "$(grep -cv '^REVIEW_[A-Z_]*=-\?[0-9]*$' "$REPO/metrics.env")"

# ---------------------------------------------------------------------------
# Mechanism 7 -- a drop is disclosed on the pull request, not only in the log
# ---------------------------------------------------------------------------

check "the main run discloses what adjudication removed" \
  '1' "$(grep -c '^\*\*Findings dropped before posting\*\*$' "$BODY")"
check "and names the count per reason" \
  '1' "$(grep -c '^2 padding (citation absent at base), 1 blindness (recorded as coverage)$' "$BODY")"

# A SOLE FINDING DROPPED AS PADDING MUST NOT POST AS CLEAN. A dropped finding
# leaves `kept` but stays in `findings`, so an empty `kept` reached the clean
# header and the only record of the drop was stdout -- which nobody reads
# when the check is green.
jf solo_pad.json '{"findings":[
{"severity":"BLOCKER","path":"CHANGELOG.md","line":0,"message":"The missing CHANGELOG entry for this change hides it from the release notes. Add one."}
]}'
: > "$REPO/m_pad.env"
orun solo_pad.json solo_pad.md m_pad.env --summary '4 files, +41/-0.' > /dev/null
check "a sole padding drop does not post as no blocking findings" \
  '0' "$(grep -c 'No blocking findings' "$REPO/solo_pad.md" || true)"
check "it says nothing survived adjudication instead" \
  '1' "$(grep -c '^\*\*No finding survived adjudication in the 4 of 4 files opened\.\*\* 1 finding dropped before posting; see below\.$' "$REPO/solo_pad.md")"
check "and the drop reaches the pull request with its reason" \
  '1' "$(grep -c '^1 padding (citation absent at base)$' "$REPO/solo_pad.md")"
check "the marker separates nothing-found from everything-dropped" \
  '1' "$(grep -c 'findings=0 blockers=0 dropped=1 ' "$REPO/solo_pad.md")"

# The same for a sole finding removed as blindness.
jf solo_blind.json '{"findings":[
{"severity":"BLOCKER","path":"logo.png","line":0,"message":"I could not open this file, so I could not review it."}
]}'
: > "$REPO/m_blind.env"
orun solo_blind.json solo_blind.md m_blind.env --summary '4 files, +41/-0.' > /dev/null
check "a sole blindness drop does not post as no blocking findings" \
  '0' "$(grep -c 'No blocking findings' "$REPO/solo_blind.md" || true)"
check "and that reason reaches the pull request too" \
  '1' "$(grep -c '^1 blindness (recorded as coverage)$' "$REPO/solo_blind.md")"

# ---------------------------------------------------------------------------
# Blindness is about the REVIEWER, not about the code
# ---------------------------------------------------------------------------
#
# A bare `cannot verify` and a bare `not visible` ate real findings, and the
# prompt's own definition of RISK -- "plausible breakage you could not
# confirm from the tree" -- steers the model into that exact wording.
jf collide.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"The error is not visible to the caller, so the failure is swallowed. Return it."},
{"severity":"BLOCKER","path":"src/auth.go","line":13,"message":"The caller cannot verify the signature before use. Check it."}
]}'
: > "$REPO/m_collide.env"
orun collide.json collide.md m_collide.env > /dev/null
check "a finding about what the CODE cannot see is not blindness" \
  '2' "$(grep -c '^- ❌ \*\*BLOCKER\*\*' "$REPO/collide.md")"
check "and nothing is rerouted to coverage" \
  '0' "$(metric_of "$REPO/m_collide.env" REVIEW_BLIND_REROUTED)"

# The reviewer's own blindness still is, in both its shapes.
jf blind2.json '{"findings":[
{"severity":"RISK","path":"logo.png","line":0,"message":"I cannot see the contents of this file."},
{"severity":"RISK","path":"src/auth.go","line":0,"message":"The change is not visible in the diff I was given."}
]}'
: > "$REPO/m_blind2.env"
orun blind2.json blind2.md m_blind2.env > /dev/null
check "the reviewer's own blindness is still rerouted" \
  '2' "$(metric_of "$REPO/m_blind2.env" REVIEW_BLIND_REROUTED)"

# The hole the first-person narrowing left. A clause with no subject at all
# opens a defect report as readily as a blindness claim -- a reviewer stating
# the symptom before the cause writes exactly this -- so the clause-start
# alternative needs a second signal before it may drop anything.
jf symptom.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"Cannot read the config when XDG_CONFIG_HOME is unset, because the loader hardcodes the path. Fix the lookup."},
{"severity":"BLOCKER","path":"src/auth.go","line":13,"message":"Unable to open the socket once the path exceeds 108 bytes, so the daemon aborts. Shorten it."}
]}'
: > "$REPO/m_symptom.env"
orun symptom.json symptom.md m_symptom.env > /dev/null
check "a subject-less defect report is not blindness" \
  '2' "$(grep -c '^- ❌ \*\*BLOCKER\*\*' "$REPO/symptom.md")"
check "and neither is rerouted to coverage" \
  '0' "$(metric_of "$REPO/m_symptom.env" REVIEW_BLIND_REROUTED)"

# The two shapes that keep the alternative worth having: the clause names the
# reviewer's view, or it ends there with no object, which no symptom does.
jf noself.json '{"findings":[
{"severity":"RISK","path":"logo.png","line":0,"message":"Cannot confirm the byte order from the diff."},
{"severity":"RISK","path":"logo.png","line":0,"message":"The row carries no patch; cannot confirm."}
]}'
: > "$REPO/m_noself.env"
orun noself.json noself.md m_noself.env > /dev/null
check "a subject-less blindness claim is still rerouted" \
  '2' "$(metric_of "$REPO/m_noself.env" REVIEW_BLIND_REROUTED)"

# ---------------------------------------------------------------------------
# Mechanism 2, the two alternatives that were not scoped to the nouns
# ---------------------------------------------------------------------------
#
# `undocumented` and `should be documented` dropped outright, at a path that
# resolves nowhere, while every other alternative in the pattern had to name
# a CHANGELOG, a README, documentation or a test first. Both of these ate a
# finding that was not about documentation at all.
jf docword.json '{"findings":[
{"severity":"BLOCKER","path":"src/missing.go","line":5,"message":"The loader relies on an undocumented ordering guarantee in the C library. Pin the version."},
{"severity":"BLOCKER","path":"src/missing.go","line":6,"message":"The workflow grants contents write; the reason should be documented and the scope narrowed to read."},
{"severity":"BLOCKER","path":"src/missing.go","line":7,"message":"The new lane flag is undocumented."},
{"severity":"BLOCKER","path":"src/missing.go","line":8,"message":"The retry semantics should be documented."}
]}'
: > "$REPO/m_docword.env"
orun docword.json docword.md m_docword.env > /dev/null
check "a dependency on an undocumented guarantee survives" \
  '1' "$(grep -c 'ordering guarantee' "$REPO/docword.md")"
check "substance riding with a documentation clause survives" \
  '1' "$(grep -c 'scope narrowed to read' "$REPO/docword.md")"
check "the predicative form is still padding" \
  '0' "$(grep -c 'lane flag' "$REPO/docword.md" || true)"
check "and so is the claim that ends at the verb" \
  '0' "$(grep -c 'retry semantics' "$REPO/docword.md" || true)"
check "exactly the two documentation claims are counted as padding" \
  '2' "$(metric_of "$REPO/m_docword.env" REVIEW_PADDING_REJECTED)"

# ---------------------------------------------------------------------------
# Mechanism 2 drops where mechanism 4 only downgrades, so they must not race
# ---------------------------------------------------------------------------
#
# The padding branch runs first and DROPS; the anchor branch only DOWNGRADES.
# With a generic `has no` in CONVENTION, two findings one word apart at the
# same unresolvable path got opposite treatment -- one vanished with no
# record, the other posted as a RISK.
jf pair.json '{"findings":[
{"severity":"BLOCKER","path":"src/missing.go","line":5,"message":"The handler has no timeout on the outbound call. Add one."},
{"severity":"BLOCKER","path":"src/missing.go","line":6,"message":"The handler lacks a timeout on the outbound call. Add one."}
]}'
: > "$REPO/m_pair.env"
orun pair.json pair.md m_pair.env > /dev/null
check "both halves of the pair reach the comment" \
  '2' "$(grep -c '^- ⚠️ \*\*RISK\*\* `src/missing.go` ' "$REPO/pair.md")"
check "neither is dropped as padding" \
  '0' "$(metric_of "$REPO/m_pair.env" REVIEW_PADDING_REJECTED)"
check "both are downgraded by the anchor rule instead" \
  '2' "$(metric_of "$REPO/m_pair.env" REVIEW_ANCHOR_DOWNGRADED)"

# ---------------------------------------------------------------------------
# CONVENTION is scoped to the artefact nouns -- ALL of it
# ---------------------------------------------------------------------------
#
# One alternative, `should (?:be )?updated`, carried no ARTEFACT, so "the
# timeout should be updated to 30s" was DROPPED -- not downgraded -- under a
# reason naming a citation it never made.
#
# `src/missing.go` resolves nowhere, which is the only condition under which
# the padding gate fires at all. Cite a path that exists and the drop this is
# about cannot happen -- the fixture would pass while the defect stood.
jf scope.json '{"findings":[
{"severity":"BLOCKER","path":"src/missing.go","line":5,"message":"The timeout should be updated to 30s or the handler hangs. Raise it."},
{"severity":"BLOCKER","path":"CHANGELOG.md","line":0,"message":"The CHANGELOG should be updated for this change."}
]}'
: > "$REPO/m_scope.env"
orun scope.json scope.md m_scope.env > /dev/null
check "a defect worded 'should be updated' survives, downgraded not deleted" \
  '1' "$(grep -c '^- ⚠️ \*\*RISK\*\* `src/missing.go` — The timeout should be updated' "$REPO/scope.md")"
check "the same wording about an artefact still is padding" \
  '0' "$(grep -c 'CHANGELOG' "$REPO/scope.md" || true)"
check "so exactly one of the pair is rejected as padding" \
  '1' "$(metric_of "$REPO/m_scope.env" REVIEW_PADDING_REJECTED)"
check "and the survivor is counted as an unresolvable anchor instead" \
  '1' "$(metric_of "$REPO/m_scope.env" REVIEW_ANCHOR_DOWNGRADED)"

# "Absent at base" is what ADDED means, so the padding gate cannot rest on
# that alone: src/new.go is in the manifest, and a convention-worded finding
# about it is a real finding about new code.
jf added.json '{"findings":[
{"severity":"BLOCKER","path":"src/new.go","line":0,"message":"The new entry point has no error handling on the write path. Add it."}
]}'
: > "$REPO/m_added.env"
orun added.json added.md m_added.env > /dev/null
check "a convention finding about a file this pull request adds survives" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/new.go`' "$REPO/added.md")"
check "and nothing about it is counted as padding" \
  '0' "$(metric_of "$REPO/m_added.env" REVIEW_PADDING_REJECTED)"

# ---------------------------------------------------------------------------
# A DOTFILE ANCHOR MUST SURVIVE INTACT
# ---------------------------------------------------------------------------
#
# The markdown parser's `location.strip().lstrip("./")` stripped leading
# CHARACTERS rather than the prefix `./`, so `.github/workflows/ci.yaml:2`
# became `github/workflows/ci.yaml` -- a path in neither the manifest nor the
# base tree. A security BLOCKER on the most-reviewed file class in this fleet
# posted as a RISK with a path that does not exist. The path is its own typed
# field now, so the mangling has nowhere left to happen; this is the
# regression test that it has not come back somewhere else.
jf dotfile.json '{"findings":[
{"severity":"BLOCKER","path":".github/workflows/ci.yaml","line":2,"message":"pull_request_target runs branch content with a write token. Use pull_request."},
{"severity":"BLOCKER","path":".gitignore","line":0,"message":"The new build output lands in the tree. Ignore it."}
]}'
: > "$REPO/m_dot.env"
orun dotfile.json dotfile.md m_dot.env > /dev/null
check "a dotfile anchor keeps BLOCKER, its leading dot and its line number" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `\.github/workflows/ci\.yaml:2` ' "$REPO/dotfile.md")"
check "the mangled path never reaches the comment" \
  '0' "$(grep -c '`github/workflows' "$REPO/dotfile.md" || true)"
check "an extensionless dotfile keeps its dot, and its severity" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `\.gitignore` ' "$REPO/dotfile.md")"
check "and neither is downgraded" \
  '0' "$(metric_of "$REPO/m_dot.env" REVIEW_ANCHOR_DOWNGRADED)"

# The schema forbids a leading `./` and an absolute path, and `conforms`
# witnesses that rather than normalising it: a path the schema said could not
# arrive, arriving, is the two checks disagreeing and is reported as such.
jf badpath.json '{"findings":[
{"severity":"BLOCKER","path":"./src/auth.go","line":12,"message":"Unvalidated input reaches the query builder. Validate it."},
{"severity":"BLOCKER","path":"/etc/passwd","line":1,"message":"The deploy script reads the host password file. Remove it."}
]}'
: > "$REPO/m_badpath.env"
orun badpath.json badpath.md m_badpath.env > /dev/null
check "a leading ./ and an absolute path are both refused, not normalised" \
  '2' "$(metric_of "$REPO/m_badpath.env" REVIEW_SCHEMA_REJECTED)"
check "and the refusal is disclosed rather than read as a clean review" \
  '1' "$(grep -c '^2 rejected by the output schema check$' "$REPO/badpath.md")"

# ---------------------------------------------------------------------------
# The headline names coverage whether or not it carries findings
# ---------------------------------------------------------------------------
#
# The clause was on the no-findings branches only, so a review REPORTING
# findings said nothing about how little it opened -- the `unmeasured` case
# wearing a verdict.
( cd "$REPO" && python3 "$SCRIPT" --findings scope.json --manifest manifest.tsv \
  --base "$BASE" --out thin_findings.md --head abc --lane C \
  --coverage-read 2 --coverage-total 40 > /dev/null )
check "a headline with findings names how much was opened" \
  '1' "$(grep -c '^\*\*1 finding in the 2 of 40 files opened\*\* — 0 blockers, 1 risk\.$' \
    "$REPO/thin_findings.md")"

# ---------------------------------------------------------------------------
# The private scratchpad
# ---------------------------------------------------------------------------

check "reviewer notes never reach the comment" \
  '0' "$(grep -c 'version table matches' "$BODY" || true)"
check "reviewer notes do reach the job log" \
  '1' "$(printf '%s\n' "$LOG" | grep -c 'version table matches')"

# ---------------------------------------------------------------------------
# A -- HOSTILE TEXT. Mechanism 12: the model may not write the comment's
# structure. The schema cannot express any of this, so it is all here.
# ---------------------------------------------------------------------------

# A1. A newline in a message ends the bullet the body is assembled from, and
# whatever follows becomes body text. It is COLLAPSED rather than refused: a
# model wrapping two sentences across a newline is writing a correct finding
# badly. One bullet, one space, and a count that says it happened.
jf a1.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"The query builder takes unvalidated input.\nValidate it before the call."}
]}'
: > "$REPO/m_a1.env"
orun a1.json a1.md m_a1.env > /dev/null
check "a newline in a message does not cost the finding" \
  '1' "$(metric_of "$REPO/m_a1.env" REVIEW_FINDINGS)"
check "the newline renders as a single space on one bullet" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/auth.go:12` — The query builder takes unvalidated input\. Validate it before the call\.$' "$REPO/a1.md")"
check "and the body carries exactly that one bullet" \
  '1' "$(grep -c '^- [^ ]* \*\*' "$REPO/a1.md")"
check "the collapse is counted" \
  '1' "$(metric_of "$REPO/m_a1.env" REVIEW_MESSAGE_NORMALISED)"
check "collapsing is not a refusal" \
  '0' "$(metric_of "$REPO/m_a1.env" REVIEW_UNSAFE_REJECTED)"

# A2. The same for every other control character, and a run of whitespace
# collapses to ONE space -- `" ".join(split())`, not a per-character
# substitution, or `\r\n` would leave two.
jf a2.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"carriage\rreturn\ttab\u0000nul   and   runs collapse."}
]}'
: > "$REPO/m_a2.env"
orun a2.json a2.md m_a2.env > /dev/null
check "a carriage return, a tab and a NUL are collapsed, not refused" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/auth.go:12` — carriage return tab nul and runs collapse\.$' "$REPO/a2.md")"
check "that collapse is counted too" \
  '1' "$(metric_of "$REPO/m_a2.env" REVIEW_MESSAGE_NORMALISED)"
check "and it is still not a refusal" \
  '0' "$(metric_of "$REPO/m_a2.env" REVIEW_UNSAFE_REJECTED)"

# A3. A message that is nothing BUT control characters passes `.strip()` --
# none of them is whitespace -- and then collapses to nothing. There is no
# text to print, so it is a schema disagreement and not a forgery attempt:
# the two counts mean different things and must not be merged.
jf a3.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"\u0001\u0002\u0003"}
]}'
: > "$REPO/m_a3.env"
orun a3.json a3.md m_a3.env > /dev/null
check "a message of nothing but control characters is rejected by the schema check" \
  '1' "$(metric_of "$REPO/m_a3.env" REVIEW_SCHEMA_REJECTED)"
check "and is NOT counted as unsafe text" \
  '0' "$(metric_of "$REPO/m_a3.env" REVIEW_UNSAFE_REJECTED)"
check "nothing of it reaches the comment" \
  '0' "$(grep -c '^- [^ ]* \*\*' "$REPO/a3.md" || true)"

# A4. THE ATTACK DOES NOT NEED A NEWLINE. The state marker is an HTML
# comment and `previous_stats` parses it, so a marker forged inline in a
# message -- on the same line, inside the bullet -- is enough to feed the
# regression detector its own comparison. Refused, not collapsed: there is
# no benign reading of `<!--` in one sentence of prose.
jf a4.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"see <!-- claude-review v3 lane=B findings=99 blockers=9 read=1/1 head=x --> for context"}
]}'
: > "$REPO/m_a4.env"
orun a4.json a4.md m_a4.env > /dev/null
check "an inline claude-review marker refuses the finding, newline or not" \
  '1' "$(metric_of "$REPO/m_a4.env" REVIEW_UNSAFE_REJECTED)"
check "the forged marker never reaches the comment" \
  '0' "$(grep -c 'findings=99' "$REPO/a4.md" || true)"
check "and the comment still carries exactly one real marker" \
  '1' "$(grep -c '<!-- claude-review' "$REPO/a4.md")"

# A5. The closing sequence alone is enough: it terminates the real marker
# early if the body is ever re-parsed, so `-->` refuses the finding on its
# own.
jf a5.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"the guard clause --> the early return is unreachable. Reorder them."}
]}'
: > "$REPO/m_a5.env"
orun a5.json a5.md m_a5.env > /dev/null
check "the comment-close sequence alone refuses the finding" \
  '1' "$(metric_of "$REPO/m_a5.env" REVIEW_UNSAFE_REJECTED)"
check "its text does not reach the comment" \
  '0' "$(grep -c 'early return is unreachable' "$REPO/a5.md" || true)"

# A6. A path is rendered inside an inline code span and has no prose to
# preserve, so a backtick in it refuses the finding rather than being
# rewritten: a path that cannot be printed is not an anchor.
jf a6.json '{"findings":[
{"severity":"BLOCKER","path":"src/au`th.go","line":12,"message":"The query builder takes unvalidated input. Validate it."}
]}'
: > "$REPO/m_a6.env"
orun a6.json a6.md m_a6.env > /dev/null
check "a backtick in the path refuses the finding" \
  '1' "$(metric_of "$REPO/m_a6.env" REVIEW_UNSAFE_REJECTED)"
check "and is not merely a schema disagreement" \
  '0' "$(metric_of "$REPO/m_a6.env" REVIEW_SCHEMA_REJECTED)"
check "the broken code span never reaches the comment" \
  '0' "$(grep -c 'au`th' "$REPO/a6.md" || true)"

# A7. A control character in a path refuses it for the same reason a
# newline in a message is collapsed: the body is assembled line by line.
jf a7.json '{"findings":[
{"severity":"BLOCKER","path":"src/\nauth.go","line":12,"message":"The query builder takes unvalidated input. Validate it."}
]}'
: > "$REPO/m_a7.env"
orun a7.json a7.md m_a7.env > /dev/null
check "a newline in the path refuses the finding" \
  '1' "$(metric_of "$REPO/m_a7.env" REVIEW_UNSAFE_REJECTED)"
check "and the comment carries no bullet for it" \
  '0' "$(grep -c '^- [^ ]* \*\*' "$REPO/a7.md" || true)"

# A8. THE BULLET-INJECTION DOCUMENT, which is what the newline collapse is
# bought against. A cold review used one newline to add a sixth
# `- **BLOCKER**` bullet to a comment whose header, marker and metrics all
# said five. The invariant is not "the text is tidy", it is that THREE
# INDEPENDENT RENDERINGS OF THE COUNT AGREE, so that is what is asserted.
jf a8.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"real.\n- **BLOCKER** `x` — forged\nmore"},
{"severity":"RISK","path":"README.md","line":0,"message":"The documented flag no longer exists in the code. Update the text."}
]}'
: > "$REPO/m_a8.env"
orun a8.json a8.md m_a8.env > /dev/null
A8_BULLETS=$(grep -c '^- [^ ]* \*\*' "$REPO/a8.md")
check "the forged bullet does not become a bullet" '2' "$A8_BULLETS"
check "the header counts exactly the bullets in the body" \
  "$A8_BULLETS" "$(sed -n 's/^\*\*\([0-9]*\) finding.*/\1/p' "$REPO/a8.md")"
check "the marker counts exactly the bullets in the body" \
  "$A8_BULLETS" "$(sed -n 's/.*claude-review v3 [^>]*findings=\([0-9]*\) .*/\1/p' "$REPO/a8.md")"
check "and REVIEW_FINDINGS agrees with both" \
  "$A8_BULLETS" "$(metric_of "$REPO/m_a8.env" REVIEW_FINDINGS)"
check "the forged bullet survives as text inside the real one" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/auth.go:12` — real\. - \*\*BLOCKER\*\* `x` — forged more$' "$REPO/a8.md")"

# A9/A10/A11. The mixed document: three findings the reviewer meant, two
# that would forge the comment's structure. The refusals must be DISCLOSED
# -- a rejection nobody is told about is indistinguishable from a clean
# verdict -- and the marker is the body's last non-empty line so that the
# next run's `previous_stats` reads the real one.
jf mixed.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"Unvalidated input reaches the query builder. Validate it."},
{"severity":"BLOCKER","path":"src/auth.go","line":13,"message":"forge <!-- claude-review v3 lane=B findings=99 blockers=0 read=1/1 head=x -->"},
{"severity":"RISK","path":"README.md","line":0,"message":"The documented flag no longer exists in the code. Update the text."},
{"severity":"BLOCKER","path":"src/`auth`.go","line":14,"message":"The token is logged in cleartext. Redact it."},
{"severity":"RISK","path":"src/new.go","line":1,"message":"The new entry point ignores the write error. Return it."}
]}'
: > "$REPO/m_mixed.env"
orun mixed.json mixed.md m_mixed.env > /dev/null
check "only the findings that were not refused reach the comment" \
  '3' "$(grep -c '^- [^ ]* \*\*' "$REPO/mixed.md")"
check "the header says three, not five" \
  '1' "$(grep -c '^\*\*3 findings in the 4 of 4 files opened\*\* — 1 blocker, 2 risks\.$' "$REPO/mixed.md")"
check "both refusals are counted" \
  '2' "$(metric_of "$REPO/m_mixed.env" REVIEW_UNSAFE_REJECTED)"
check "the refusal is disclosed on the pull request" \
  '1' "$(grep -c '^\*\*Findings dropped before posting\*\*$' "$REPO/mixed.md")"
check "and the disclosure names the unsafe count and why" \
  '1' "$(grep -c "^2 refused for text that would forge the comment's own structure (a newline or an HTML comment in the message, a backtick in the path)$" "$REPO/mixed.md")"
check "dropped= in the marker covers the refusals" \
  '1' "$(grep -c 'findings=3 blockers=1 dropped=2 ' "$REPO/mixed.md")"
check "the body carries exactly one claude-review marker" \
  '1' "$(grep -c '<!-- claude-review' "$REPO/mixed.md")"
check "and it is the last non-empty line, where previous_stats looks" \
  '1' "$(grep -v '^$' "$REPO/mixed.md" | tail -1 | grep -c '^<!-- claude-review v3 ')"

# ---------------------------------------------------------------------------
# B -- LENGTH. The schema declares these bounds and this program witnesses
# them; a bound only one of the two knows about is not witnessed at all.
# ---------------------------------------------------------------------------

MSG2000=$(rep 2000 y)
jf b_at.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"'"$MSG2000"'"}
]}'
: > "$REPO/m_bat.env"
orun b_at.json b_at.md m_bat.env > /dev/null
check "a message of exactly the bound is accepted" \
  '1' "$(metric_of "$REPO/m_bat.env" REVIEW_FINDINGS)"
check "and nothing about it is rejected" \
  '0' "$(metric_of "$REPO/m_bat.env" REVIEW_SCHEMA_REJECTED)"

MSG2001=$(rep 2001 y)
jf b_over.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"'"$MSG2001"'"}
]}'
: > "$REPO/m_bover.env"
orun b_over.json b_over.md m_bover.env > /dev/null
check "one character past the bound is rejected" \
  '1' "$(metric_of "$REPO/m_bover.env" REVIEW_SCHEMA_REJECTED)"
check "and no finding reaches the comment" \
  '0' "$(metric_of "$REPO/m_bover.env" REVIEW_FINDINGS)"

PATH4097=$(rep 4097 p)
jf b_path.json '{"findings":[
{"severity":"BLOCKER","path":"'"$PATH4097"'","line":0,"message":"The vendored path is checked in. Remove it."}
]}'
: > "$REPO/m_bpath.env"
orun b_path.json b_path.md m_bpath.env > /dev/null
check "a path past the bound is rejected" \
  '1' "$(metric_of "$REPO/m_bpath.env" REVIEW_SCHEMA_REJECTED)"

# MEASURED BEFORE COLLAPSE, because that is the string the schema measured.
# A 2001-character message that would collapse to one character is still
# refused: a second witness that measured something else would not be one.
B_PAD=$(rep 2000 ' ')
jf b_pre.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"x'"$B_PAD"'"}
]}'
: > "$REPO/m_bpre.env"
orun b_pre.json b_pre.md m_bpre.env > /dev/null
check "length is measured before the collapse, not after" \
  '1' "$(metric_of "$REPO/m_bpre.env" REVIEW_SCHEMA_REJECTED)"
check "so it never becomes a one-character finding" \
  '0' "$(metric_of "$REPO/m_bpre.env" REVIEW_FINDINGS)"

# THE SCHEMA AND THE CONSTANTS MUST NOT DRIFT APART. The bounds live in two
# files on purpose -- the CLI enforces one, this program witnesses the other
# -- and a witness checking a different number is worse than no witness.
check "review-schema.json declares the message bound this program witnesses" \
  '2000' "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(d["properties"]["findings"]["items"]["properties"]["message"]["maxLength"])' "$SCHEMA")"
check "review-schema.json declares the path bound this program witnesses" \
  '4096' "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(d["properties"]["findings"]["items"]["properties"]["path"]["maxLength"])' "$SCHEMA")"
check "and the program's own constants are those two numbers" \
  '2000 4096' "$(cd "$HERE" && python3 -c \
    'import review_output as r; print(r.MESSAGE_LIMIT, r.PATH_LIMIT)')"

# ---------------------------------------------------------------------------
# C -- line_count and anchor_verdict. NEWLINES ARE TERMINATORS, NOT
# SEPARATORS, which is what `wc -l`, an editor's gutter and GitHub's blob
# view all mean by a line number. `newlines + 1` added a phantom final line
# to every file that ends in one, so "a line past the end of the file costs
# the finding its severity" cost nothing for the first line past it.
# ---------------------------------------------------------------------------

crun() { # crun <findings> <out> <metrics> -> stdout, against lines.tsv
  ( cd "$REPO" && python3 "$SCRIPT" --findings "$1" --manifest lines.tsv \
      --base "$BASE" --out "$2" --metrics "$3" --head abc --lane B \
      --coverage-read 4 --coverage-total 4 )
}

check "line_count counts terminators, not phantom final lines" \
  '3 3 0 -1' "$(cd "$REPO" && python3 -c \
    'import sys; sys.path.insert(0, sys.argv[1]); import review_output as r;
print(r.line_count("src/three.txt"), r.line_count("src/notrail.txt"),
      r.line_count("src/empty.txt"), r.line_count("src/gone.go"))' "$HERE")"

# C16 -- a file that ends in a newline. Line 3 is real; line 4 is not.
jf c_last.json '{"findings":[
{"severity":"BLOCKER","path":"src/three.txt","line":3,"message":"The last entry shadows the first. Rename it."}
]}'
: > "$REPO/m_clast.env"
crun c_last.json c_last.md m_clast.env > /dev/null
check "the last line of a newline-terminated file is a valid anchor" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/three.txt:3` ' "$REPO/c_last.md")"
check "and nothing is downgraded" \
  '0' "$(metric_of "$REPO/m_clast.env" REVIEW_ANCHOR_DOWNGRADED)"

jf c_past.json '{"findings":[
{"severity":"BLOCKER","path":"src/three.txt","line":4,"message":"The last entry shadows the first. Rename it."}
]}'
: > "$REPO/m_cpast.env"
crun c_past.json c_past.md m_cpast.env > /dev/null
check "the phantom line after the terminator is not a valid anchor" \
  '1' "$(grep -c '^- ⚠️ \*\*RISK\*\* `src/three.txt` ' "$REPO/c_past.md")"
check "the downgrade drops the number as well as the severity" \
  '0' "$(grep -c 'src/three.txt:' "$REPO/c_past.md" || true)"
check "and it is counted" \
  '1' "$(metric_of "$REPO/m_cpast.env" REVIEW_ANCHOR_DOWNGRADED)"

# C17 -- a file with NO trailing newline. Its last line is real and
# unterminated, so the discriminator is the last byte and not a `+ 1`
# applied to everything.
jf c_nt.json '{"findings":[
{"severity":"BLOCKER","path":"src/notrail.txt","line":3,"message":"The last entry shadows the first. Rename it."}
]}'
: > "$REPO/m_cnt.env"
crun c_nt.json c_nt.md m_cnt.env > /dev/null
check "an unterminated last line is still a line" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/notrail.txt:3` ' "$REPO/c_nt.md")"
check "and nothing is downgraded for it" \
  '0' "$(metric_of "$REPO/m_cnt.env" REVIEW_ANCHOR_DOWNGRADED)"

jf c_nt_past.json '{"findings":[
{"severity":"BLOCKER","path":"src/notrail.txt","line":4,"message":"The last entry shadows the first. Rename it."}
]}'
: > "$REPO/m_cntp.env"
crun c_nt_past.json c_nt_past.md m_cntp.env > /dev/null
check "one line past an unterminated file is downgraded" \
  '1' "$(metric_of "$REPO/m_cntp.env" REVIEW_ANCHOR_DOWNGRADED)"

# C18 -- an empty file is 0 lines and therefore has NO valid anchor. The
# old form claimed it had one, so line 1 of an empty file resolved.
jf c_empty.json '{"findings":[
{"severity":"BLOCKER","path":"src/empty.txt","line":1,"message":"The placeholder is committed with no content. Remove it."}
]}'
: > "$REPO/m_cempty.env"
crun c_empty.json c_empty.md m_cempty.env > /dev/null
check "line 1 of an empty file is not a valid anchor" \
  '1' "$(metric_of "$REPO/m_cempty.env" REVIEW_ANCHOR_DOWNGRADED)"
check "and the finding posts as a RISK with no line" \
  '1' "$(grep -c '^- ⚠️ \*\*RISK\*\* `src/empty.txt` ' "$REPO/c_empty.md")"

# C19 -- `line: 0` is the schema's "not line-specific", so there is no
# anchor to resolve and nothing to downgrade. Treating it as unresolvable
# would demote every deliberately file-wide BLOCKER.
jf c_zero.json '{"findings":[
{"severity":"BLOCKER","path":"src/empty.txt","line":0,"message":"The placeholder is committed with no content. Remove it."}
]}'
: > "$REPO/m_czero.env"
crun c_zero.json c_zero.md m_czero.env > /dev/null
check "line 0 keeps BLOCKER even where no line could resolve" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/empty.txt` ' "$REPO/c_zero.md")"
check "and is not counted as an unresolvable anchor" \
  '0' "$(metric_of "$REPO/m_czero.env" REVIEW_ANCHOR_DOWNGRADED)"

# C20 -- a path the checkout does not hold. `line_count` returns -1 and the
# comparison must not read that as "any line is fine".
jf c_gone.json '{"findings":[
{"severity":"BLOCKER","path":"src/gone.go","line":2,"message":"The deleted handler is still registered at startup. Unregister it."}
]}'
: > "$REPO/m_cgone.env"
crun c_gone.json c_gone.md m_cgone.env > /dev/null
check "an anchor in a file that cannot be read is downgraded" \
  '1' "$(metric_of "$REPO/m_cgone.env" REVIEW_ANCHOR_DOWNGRADED)"
check "and posts as a RISK with no line number" \
  '1' "$(grep -c '^- ⚠️ \*\*RISK\*\* `src/gone.go` ' "$REPO/c_gone.md")"

# The traversal guard is explicit rather than an accident of the dots being
# eaten. `known` already bounds the caller to manifest and base paths; this
# is the second lock, stated where the file is opened.
check "line_count refuses a path outside the checkout" \
  '-1 -1' "$(cd "$HERE" && python3 -c \
    'import review_output as r; print(r.line_count("/etc/hostname"), r.line_count("../outside.txt"))')"

# C21 -- A SYMLINK DEFEATS BOTH CHECKS ABOVE. The path is neither absolute
# nor `..`-bearing, so a link to `/dev/zero` reaches the chunk loop -- which
# bounds memory, not time -- and the adjudicate step runs until the job's
# `timeout-minutes` cancels it and the pull request gets the "did not
# finish" comment. The quieter half of the same hole is a link to a regular
# file OUTSIDE the checkout: it answers, from content the reviewer never saw.
#
# Nothing here is committed. A manifest row is what makes a path `known`,
# which is the condition under which `anchor_verdict` opens it at all.
printf 'seven\nlines\nof\ncontent\nin\nanother\ntree\n' > "$WORK/outside.txt"
ln -sf /dev/zero "$REPO/src/endless.txt"
ln -sf "$WORK/outside.txt" "$REPO/src/elsewhere.txt"
ln -sf three.txt "$REPO/src/alias.txt"
{
  printf 'added\t1\tsrc/endless.txt\tpr-files/0001.patch\n'
  printf 'added\t1\tsrc/elsewhere.txt\tpr-files/0002.patch\n'
  printf 'added\t1\tsrc/alias.txt\tpr-files/0003.patch\n'
} > "$REPO/links.tsv"

count_of() { # count_of <repo-relative path> -> line_count, or TIMED OUT
  ( cd "$REPO" && timeout 10 python3 -c \
    'import sys; sys.path.insert(0, sys.argv[1]); import review_output as r;
print(r.line_count(sys.argv[2]))' "$HERE" "$1" ) || echo "TIMED OUT"
}

check "line_count refuses a symlink to an endless file rather than reading it" \
  '-1' "$(count_of src/endless.txt)"
check "a symlink out of the checkout is refused, not measured through" \
  '-1' "$(count_of src/elsewhere.txt)"
check "and so is a symlink to a normal file inside it" \
  '-1' "$(count_of src/alias.txt)"

# END TO END, because the in-repo link is the case a real pull request adds:
# the finding must still POST, downgraded and counted like any other anchor
# that did not resolve, rather than be dropped or silently resolved against
# the target's length.
jf c_link.json '{"findings":[
{"severity":"BLOCKER","path":"src/alias.txt","line":2,"message":"The alias points at the retired path and callers follow it. Repoint it."}
]}'
: > "$REPO/m_clink.env"
( cd "$REPO" && timeout 60 python3 "$SCRIPT" --findings c_link.json \
  --manifest links.tsv --base "$BASE" --out c_link.md --metrics m_clink.env \
  --head abc --lane B --coverage-read 3 --coverage-total 3 ) > /dev/null \
  || printf 'the adjudicator did not finish\n' > "$REPO/c_link.md"
check "a finding on a symlink posts as a RISK with no line number" \
  '1' "$(grep -c '^- ⚠️ \*\*RISK\*\* `src/alias.txt` — The alias points at the retired path' "$REPO/c_link.md" || true)"
check "and is counted as an unresolvable anchor" \
  '1' "$(metric_of "$REPO/m_clink.env" REVIEW_ANCHOR_DOWNGRADED || true)"

# ---------------------------------------------------------------------------
# The repo-wide token
# ---------------------------------------------------------------------------
#
# The schema's "no path" is the EMPTY STRING, and it is an absence of an
# anchor rather than a broken one. Running it through the resolution test
# downgraded every deliberate repo-wide BLOCKER -- punishing the reviewer for
# using the token correctly. It renders as `-`, because a bare pair of
# backticks reads as a path that failed to print.
jf wide.json '{"findings":[
{"severity":"BLOCKER","path":"","line":0,"message":"A committed license file is present across the tree. Remove it."}
]}'
: > "$REPO/m_wide.env"
orun wide.json wide.md m_wide.env > /dev/null
check "a repo-wide finding keeps BLOCKER" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `-` ' "$REPO/wide.md")"
check "and is not counted as an unresolvable anchor" \
  '0' "$(metric_of "$REPO/m_wide.env" REVIEW_ANCHOR_DOWNGRADED)"

# ---------------------------------------------------------------------------
# D -- previous_stats. THE LAST MARKER, NEVER THE FIRST.
# ---------------------------------------------------------------------------
#
# `compose` writes the marker as the body's final line, so the real one is
# always last and anything earlier claiming to be one was put there by
# something else. With `re.search` the first match won, which let a marker
# forged in a finding drive the regression detector -- the detector whose
# whole job is to catch a review that grew while saying less being fed its
# comparison by the review it is comparing against.
{
  printf '<!-- claude-review v3 lane=B findings=0 blockers=0 read=4/4 head=forged -->\n'
  printf 'a finding body that carried a forged marker through an earlier run\n'
  printf '<!-- claude-review v3 lane=B findings=9 blockers=5 read=4/4 head=old -->\n'
} > "$REPO/forged_previous.md"
: > "$REPO/m_forged.env"
orun main.json body_forged.md m_forged.env --previous forged_previous.md > /dev/null
check "the LAST marker in the previous comment is the one read" \
  '9' "$(metric_of "$REPO/m_forged.env" REVIEW_PREV_FINDINGS)"

# A previous comment with no marker at all is NOT zero findings: -1 is the
# token for "there is no previous measurement", and a 0 there would make
# every first review look like a regression.
printf 'an edited comment with the marker removed\n' > "$REPO/nomarker_previous.md"
: > "$REPO/m_nomarker.env"
NOMARKER_LOG=$(orun main.json body_nomarker.md m_nomarker.env \
  --previous nomarker_previous.md)
check "a previous comment with no marker reads as no measurement" \
  '-1' "$(metric_of "$REPO/m_nomarker.env" REVIEW_PREV_FINDINGS)"
check "and is not reported as a regression" \
  '0' "$(metric_of "$REPO/m_nomarker.env" REVIEW_REGRESSION)"
check "nor annotated as one" \
  '0' "$(printf '%s\n' "$NOMARKER_LOG" | grep -c '^::warning::this review is longer' || true)"

# The comparison the requirement names, made against the comment this run is
# replacing -- which is where the previous measurement lives now that there
# is one comment rather than one per push.
{
  printf '<!-- claude-review v3 lane=B findings=9 blockers=5 read=4/4 head=old -->\n'
  rep 200 x
  printf '\n'
} > "$REPO/short_previous.md"
: > "$REPO/m_reg.env"
REG_LOG=$(orun main.json body_reg.md m_reg.env --previous short_previous.md)
check "a longer run with fewer findings is flagged" \
  '1' "$(metric_of "$REPO/m_reg.env" REVIEW_REGRESSION)"
check "and it says so as a warning annotation" \
  '1' "$(printf '%s\n' "$REG_LOG" | grep -c '^::warning::this review is longer')"

{
  printf '<!-- claude-review v3 lane=B findings=1 blockers=0 read=4/4 head=old -->\n'
  rep 9000 x
  printf '\n'
} > "$REPO/long_previous.md"
: > "$REPO/m_noreg.env"
orun main.json body_noreg.md m_noreg.env --previous long_previous.md > /dev/null
check "a shorter run with more findings is not flagged" \
  '0' "$(metric_of "$REPO/m_noreg.env" REVIEW_REGRESSION)"

: > "$REPO/m_noprev.env"
orun main.json body_noprev.md m_noprev.env --previous absent.md > /dev/null
check "no previous comment is not a regression" \
  '0' "$(metric_of "$REPO/m_noprev.env" REVIEW_REGRESSION)"

# ---------------------------------------------------------------------------
# E -- FLAGS. A mistyped flag used to become its default silently, so
# `--coverage-total` with a typo rendered "(review coverage unmeasured)" --
# a wrong measurement rather than a loud failure, in a program built on the
# principle that an unmeasured thing must never render as a measured one.
# ---------------------------------------------------------------------------

set +e
UNKNOWN_ERR=$( cd "$REPO" && python3 "$SCRIPT" --findings main.json \
  --manifest manifest.tsv --base "$BASE" --out unknown.md \
  --coverage-reed 3 --coverage-total 4 2>&1 >/dev/null )
UNKNOWN_STATUS=$?
set -e
check "an unknown flag exits 2 rather than defaulting" '2' "$UNKNOWN_STATUS"
check "and stderr names the token that was not understood" \
  '1' "$(printf '%s\n' "$UNKNOWN_ERR" | grep -c -- '--coverage-reed')"
check "no comment is written when the arguments are misuse" \
  '0' "$([ -e "$REPO/unknown.md" ] && echo 1 || echo 0)"

set +e
( cd "$REPO" && python3 "$SCRIPT" --findings main.json --manifest manifest.tsv \
  --base "$BASE" --out dangling.md --metrics ) > /dev/null 2>&1
DANGLING_STATUS=$?
set -e
check "a known flag with no value is misuse too" '2' "$DANGLING_STATUS"
check "and writes no comment either" \
  '0' "$([ -e "$REPO/dangling.md" ] && echo 1 || echo 0)"

# THE ARGV THE WORKFLOW ACTUALLY SENDS, all fourteen flags, in its order.
# `check_flags` is fatal, so a flag this program stops accepting takes every
# consuming repository's review down at once -- and the workflow and these
# programs are checked out at ONE commit, so that is a defect inside a single
# commit rather than version drift.
: > "$REPO/m_argv.env"
set +e
( cd "$REPO" && python3 "$SCRIPT" \
  --findings main.json \
  --manifest manifest.tsv \
  --base "$BASE" \
  --out argv.md \
  --sections sections.tsv \
  --notes notes.txt \
  --previous short_previous.md \
  --metrics m_argv.env \
  --head abc \
  --lane B \
  --coverage-read 3 \
  --coverage-total 4 \
  --summary '4 files, +41/-0.' \
  --restored '.claude CLAUDE.md .ripgreprc .gitmodules .husky' ) > /dev/null 2>&1
ARGV_STATUS=$?
set -e
check "the exact argv the workflow sends is accepted" '0' "$ARGV_STATUS"
check "and it produces a comment" \
  '1' "$([ -s "$REPO/argv.md" ] && echo 1 || echo 0)"

# A PAIRWISE WALK, not `argv.index`. The index form matched a flag name
# appearing as another flag's VALUE and returned the token after it, and
# `--summary` carries author-influenced text, so that was reachable from the
# pull request itself.
check "a flag name used as another flag's value is not mistaken for the flag" \
  'realsha' "$(cd "$HERE" && python3 -c \
    'import review_output as r
print(r._flag(["--restored", "--head", "--head", "realsha"], "--head"))')"

check "--help prints usage and exits 0" \
  'usage: review_output.py --findings <file> --manifest <file> --base <rev>' \
  "$(python3 "$SCRIPT" --help | head -1)"
check "-h is the same request" \
  '0' "$(python3 "$SCRIPT" -h > /dev/null; echo $?)"

# ---------------------------------------------------------------------------
# F -- NO STRUCTURED OUTPUT IS NOT A CLEAN VERDICT
# ---------------------------------------------------------------------------
#
# `{"findings": []}` is the clean verdict and says so unambiguously, because
# the model had to produce it. A run that produced no object at all
# adjudicated nothing, which is a different thing: a review naming real
# defects would otherwise go out as "no blocking findings" and exit green.

jf clean.json '{"findings":[]}'
: > "$REPO/m_clean.env"
orun clean.json clean.md m_clean.env --summary '4 files, +41/-0.' > /dev/null
check "an empty findings array is the clean verdict" \
  '1' "$(grep -c '^✅ \*\*No blocking findings in the 4 of 4 files opened\.\*\* 4 files, +41/-0\.$' "$REPO/clean.md")"
check "a clean review still carries a marker" \
  '1' "$(grep -c 'findings=0 blockers=0' "$REPO/clean.md")"
check "an explicit clean verdict is not flagged as missing" \
  '0' "$(metric_of "$REPO/m_clean.env" REVIEW_NO_VERDICT)"

# EVERY METRIC IS WRITTEN ON EVERY RUN. A metric that appears only when it
# is non-zero cannot be told from a metric that stopped being written, which
# is how a mechanism silently dies.
check "REVIEW_UNSAFE_REJECTED is written on a clean run" \
  '1' "$(grep -c '^REVIEW_UNSAFE_REJECTED=0$' "$REPO/m_clean.env")"
check "REVIEW_MESSAGE_NORMALISED is written on a clean run" \
  '1' "$(grep -c '^REVIEW_MESSAGE_NORMALISED=0$' "$REPO/m_clean.env")"
check "and so is every other one, nineteen in all" \
  '19' "$(grep -c '^REVIEW_' "$REPO/m_clean.env")"

# A findings file that is not there at all. `load`'s early returns all carry
# the same three-element shape; one of them returning a bare 0 for the count
# is the kind of defect this asserts against.
: > "$REPO/m_absent.env"
ABSENT_LOG=$(orun absent.json absent.md m_absent.env)
check "a missing findings file does not post as clean" \
  '0' "$(grep -c 'No blocking findings' "$REPO/absent.md" || true)"
check "it says the reviewer produced no structured output" \
  '1' "$(grep -c '^\*\*The reviewer produced no structured output\.\*\* No finding and no verdict could be read from the run, so nothing on this pull request has been adjudicated by this check\.$' "$REPO/absent.md")"
check "and it is annotated as a warning" \
  '1' "$(printf '%s\n' "$ABSENT_LOG" | grep -c '^::warning::the reviewer produced no structured output')"
check "the outcome is distinguishable from clean" \
  '1' "$(metric_of "$REPO/m_absent.env" REVIEW_NO_VERDICT)"
check "a run that read no verdict still produces a comment with a marker" \
  '1' "$(grep -c 'claude-review v3' "$REPO/absent.md")"

# The three other ways the file can carry nothing adjudicable. Each must
# reach the same verdict, because each means the same thing.
printf 'not json at all\n' > "$REPO/notjson.json"
: > "$REPO/m_notjson.env"
orun notjson.json notjson.md m_notjson.env > /dev/null
check "a findings file that is not JSON reads as no verdict" \
  '1' "$(metric_of "$REPO/m_notjson.env" REVIEW_NO_VERDICT)"

jf nolist.json '{"finding":"one"}'
: > "$REPO/m_nolist.env"
orun nolist.json nolist.md m_nolist.env > /dev/null
check "JSON with no findings array reads as no verdict" \
  '1' "$(metric_of "$REPO/m_nolist.env" REVIEW_NO_VERDICT)"

: > "$REPO/blank.json"
: > "$REPO/m_blank.env"
orun blank.json blank.md m_blank.env > /dev/null
check "an empty findings file reads as no verdict" \
  '1' "$(metric_of "$REPO/m_blank.env" REVIEW_NO_VERDICT)"

# An entry that is not an object of the declared shape is REJECTED and
# counted, never repaired. Repairing one -- a truncation, a default, a guess
# at a severity -- is what the markdown layer did, and every one of those
# repairs was a defect found later. `true` as a line is the one worth naming:
# `bool` is a subclass of `int`, so it would otherwise resolve to line 1.
jf junk.json '{"findings":[
"a bare string",
{"severity":"WARNING","path":"src/auth.go","line":12,"message":"An unknown severity."},
{"severity":"BLOCKER","path":"src/auth.go","line":"12","message":"A line number as a string."},
{"severity":"BLOCKER","path":"src/auth.go","line":true,"message":"A boolean line number."},
{"severity":"BLOCKER","path":"src/auth.go","line":-1,"message":"A negative line number."},
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"   "},
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"Unvalidated input reaches the query builder. Validate it."}
]}'
: > "$REPO/m_junk.env"
orun junk.json junk.md m_junk.env > /dev/null
check "every object that does not conform is rejected and counted" \
  '6' "$(metric_of "$REPO/m_junk.env" REVIEW_SCHEMA_REJECTED)"
check "the one conforming finding still reaches the comment" \
  '1' "$(metric_of "$REPO/m_junk.env" REVIEW_FINDINGS)"
check "and the document was adjudicated, so it is not a missing verdict" \
  '0' "$(metric_of "$REPO/m_junk.env" REVIEW_NO_VERDICT)"

# ---------------------------------------------------------------------------
# Mechanism 8 -- the clean line carries its own denominator
# ---------------------------------------------------------------------------
#
# `**No blocking findings.** 40 files, +6654/-724.` went out over 40 files on
# the strength of 2 opened, and read identically to the same line over 40 --
# the 2026-10-21 shape with a footnote. With `warn` the default enforcement,
# that is the default fleet experience.
( cd "$REPO" && python3 "$SCRIPT" --findings clean.json --manifest manifest.tsv \
  --base "$BASE" --out thin.md --head abc --lane C \
  --coverage-read 2 --coverage-total 40 --summary '40 files, +6654/-724.' > /dev/null )
check "the clean headline names how much was opened" \
  '1' "$(grep -c '^✅ \*\*No blocking findings in the 2 of 40 files opened\.\*\* 40 files, +6654/-724\.$' "$REPO/thin.md")"
check "and the marker carries the same measurement" \
  '1' "$(grep -c 'findings=0 blockers=0 dropped=0 read=2/40 ' "$REPO/thin.md")"

# review_coverage.py writes `unmeasured` when nothing could be matched. It is
# a TOKEN: rendered as a number it would read as a measurement of nothing,
# which is the one thing it exists not to say.
( cd "$REPO" && python3 "$SCRIPT" --findings clean.json --manifest manifest.tsv \
  --base "$BASE" --out unmeasured.md --head abc --lane C \
  --coverage-read unmeasured --coverage-total unmeasured \
  --summary '40 files, +6654/-724.' > /dev/null )
check "the unmeasured token does not render as a count" \
  '1' "$(grep -c '^✅ \*\*No blocking findings (review coverage unmeasured)\.\*\* 40 files, +6654/-724\.$' "$REPO/unmeasured.md")"
check "and it reaches the marker unchanged" \
  '1' "$(grep -c 'read=unmeasured/unmeasured ' "$REPO/unmeasured.md")"

# ---------------------------------------------------------------------------
# Nothing may claim a finding is in the comment when it is not
# ---------------------------------------------------------------------------

# Blockers before risks, and no more than five, chosen here rather than
# trusted to the model's own cap.
{
  printf '{"findings":['
  for i in $(seq 1 4); do
    printf '{"severity":"RISK","path":"src/auth.go","line":%s,"message":"Risk number %s here. Fix it."},' "$i" "$i"
  done
  for i in $(seq 5 8); do
    printf '{"severity":"BLOCKER","path":"src/auth.go","line":%s,"message":"Blocker number %s here. Fix it."}' "$i" "$i"
    [ "$i" -lt 8 ] && printf ','
  done
  printf ']}\n'
} > "$REPO/many.json"
: > "$REPO/m_many.env"
orun many.json many.md m_many.env > /dev/null
check "at most five findings reach the comment" \
  '5' "$(grep -c '^- [^ ]* \*\*' "$REPO/many.md")"
check "blockers are kept before risks" \
  '4' "$(grep -c '^- ❌ \*\*BLOCKER\*\*' "$REPO/many.md")"
# The FINDING_LIMIT overflow. `rank` discarded findings 6..N with no number
# anywhere: the comment, the header and the metrics all said five.
check "the findings past the cap are counted" \
  '3' "$(metric_of "$REPO/m_many.env" REVIEW_DROPPED_FOR_SPACE)"
check "and the header says so" \
  '1' "$(grep -c '^\*\*5 findings in the 4 of 4 files opened\*\* — 4 blockers, 1 risk\. 3 withheld for space\.$' "$REPO/many.md")"

# THE BODY LIMIT. `assemble` trims by dropping findings, but the header and
# the marker were computed from the untrimmed list -- so a BLOCKER vanished
# from the comment while it still said how many blockers were in it, and
# REVIEW_FINDINGS reported the pre-trim number. Six long findings and a
# section big enough to push the body past BODY_LIMIT.
{
  printf '{"findings":['
  for i in $(seq 1 6); do
    printf '{"severity":"BLOCKER","path":"src/auth.go","line":%s,"message":"%s %s"}' \
      "$i" "$(rep 380 w)" "$i"
    [ "$i" -lt 6 ] && printf ','
  done
  printf ']}\n'
} > "$REPO/fat.json"
printf 'Files the reviewer did not open\t%s\n' "$(rep 1900 f)" \
  > "$REPO/big_sections.tsv"
: > "$REPO/m_fat.env"
orun fat.json trim.md m_fat.env --sections big_sections.tsv > /dev/null
TRIM_LINES=$(grep -c '^- [^ ]* \*\*' "$REPO/trim.md")
check "the body limit bit, so this fixture tests what it says it does" \
  '1' "$([ "$TRIM_LINES" -lt 5 ] && echo 1 || echo 0)"
check "the comment is inside the body limit" \
  '1' "$([ "$(chars_in "$REPO/trim.md")" -le 4000 ] && echo 1 || echo 0)"
check "the header counts only the findings the comment carries" \
  "$TRIM_LINES" "$(sed -n 's/^\*\*\([0-9]*\) finding.*/\1/p' "$REPO/trim.md")"
check "the marker counts only the findings the comment carries" \
  "$TRIM_LINES" "$(sed -n 's/.*claude-review v3 [^>]*findings=\([0-9]*\) .*/\1/p' "$REPO/trim.md")"
check "REVIEW_FINDINGS is the post-trim number too" \
  "$TRIM_LINES" "$(metric_of "$REPO/m_fat.env" REVIEW_FINDINGS)"
check "and everything withheld is counted, cap and budget together" \
  "$((6 - TRIM_LINES))" "$(metric_of "$REPO/m_fat.env" REVIEW_DROPPED_FOR_SPACE)"

# WHEN ONE FINDING IS LEFT, THE BUDGET YIELDS. The previous version cut that
# finding's text instead, and that cut is what deleted two security blockers
# from a comment whose own sentence said nothing had been discarded. Nothing
# is merged now, so the only routes here are one very long message or a very
# large disclosure section -- and in both, a comment slightly over a
# self-imposed readability budget beats a shortened finding. GitHub's own
# limit is 65,536.
jf sole.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"'"$(rep 2000 z)"'"}
]}'
printf 'Files the reviewer did not open\t%s\n' "$(rep 2000 f)" \
  > "$REPO/huge_sections.tsv"
: > "$REPO/m_sole.env"
orun sole.json sole.md m_sole.env --sections huge_sections.tsv > /dev/null
check "a sole over-budget finding is kept, not dropped to make room" \
  '1' "$(metric_of "$REPO/m_sole.env" REVIEW_FINDINGS)"
check "and nothing is recorded as withheld for space" \
  '0' "$(metric_of "$REPO/m_sole.env" REVIEW_DROPPED_FOR_SPACE)"
check "its message is intact rather than cut to fit" \
  '1' "$(grep -cE "z{2000}" "$REPO/sole.md")"
check "so the comment is over the readability budget, deliberately" \
  '1' "$([ "$(chars_in "$REPO/sole.md")" -gt 4000 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# Mechanism 9 -- the same finding twice is ONE finding
# ---------------------------------------------------------------------------
#
# Structured output removes the question the old rule was answering. A
# finding is an object with a severity, a path, a line and a message, so "the
# same finding twice" is an IDENTITY -- same path, same line, same message
# once punctuation and case are set aside -- and not a judgement about shared
# vocabulary. NOTHING IS MERGED, so no message grows, and the budget defect a
# merge once caused cannot recur.
jf dup.json '{"findings":[
{"severity":"RISK","path":"README.md","line":0,"message":"The README publishes an AWS account identifier."},
{"severity":"BLOCKER","path":"README.md","line":0,"message":"the readme publishes an AWS account identifier!"}
]}'
: > "$REPO/m_dup.env"
orun dup.json dup.md m_dup.env > /dev/null
check "the same sentence twice reaches the comment once" \
  '1' "$(grep -c '^- [^ ]* \*\*' "$REPO/dup.md")"
check "and the collapse is counted" \
  '1' "$(metric_of "$REPO/m_dup.env" REVIEW_DUPLICATES)"
# HIGHEST severity, not the first one seen: the RISK is the representative
# here, so a collapse that kept its severity would turn a BLOCKER into a
# RISK -- the one direction this program must never move a finding.
check "the group keeps the highest severity of its members" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `README.md` ' "$REPO/dup.md")"
# A COLLAPSE IS NOT A DROP. The surviving copy carries the text, so the drop
# row must not claim a withholding and the marker must not count one.
check "the collapse is disclosed as a duplicate, not as a drop" \
  '1' "$(grep -c '^1 finding was reported more than once, identically\. One copy of each is in the comment above; no distinct wording was discarded\.$' "$REPO/dup.md")"
check "no drop row is emitted, because nothing was dropped" \
  '0' "$(grep -c 'Findings dropped before posting' "$REPO/dup.md" || true)"
check "and the marker does not count the duplicate as removed" \
  '1' "$(grep -c 'findings=1 blockers=1 dropped=0 ' "$REPO/dup.md")"

# TWO DISTINCT FINDINGS ABOUT ONE FILE MUST SURVIVE AS TWO. This is the
# failure the old vocabulary rule traded away -- it collapsed "the install
# command points at the wrong branch" with "the build command is unquoted" on
# the word `command` -- and the identity rule does not.
jf distinct.json '{"findings":[
{"severity":"BLOCKER","path":"README.md","line":0,"message":"The install command points at the wrong branch."},
{"severity":"BLOCKER","path":"README.md","line":0,"message":"The build command is unquoted."}
]}'
: > "$REPO/m_distinct.env"
orun distinct.json distinct.md m_distinct.env > /dev/null
check "two distinct findings about one file are not collapsed" \
  '2' "$(grep -c '^- ❌ \*\*BLOCKER\*\*' "$REPO/distinct.md")"
check "and nothing is counted as a duplicate" \
  '0' "$(metric_of "$REPO/m_distinct.env" REVIEW_DUPLICATES)"

# CONTRADICTING ANCHORS ARE DIFFERENT CLAIMS even when the words are
# identical. `collapse` keys on the line AS THE REVIEWER GAVE IT, because
# mechanism 4 zeroes the rendered one on a downgrade and two downgraded
# findings at different lines would otherwise become one.
jf lines.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"Unvalidated input reaches the query builder."},
{"severity":"BLOCKER","path":"src/auth.go","line":13,"message":"Unvalidated input reaches the query builder."}
]}'
: > "$REPO/m_lines.env"
orun lines.json lines2.md m_lines.env > /dev/null
check "identical wording at two different lines stays two findings" \
  '2' "$(grep -c '^- ❌ \*\*BLOCKER\*\*' "$REPO/lines2.md")"
check "and neither is counted as a duplicate" \
  '0' "$(metric_of "$REPO/m_lines.env" REVIEW_DUPLICATES)"

jf downgraded_pair.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":9998,"message":"Possible nil dereference at the end of the file."},
{"severity":"BLOCKER","path":"src/auth.go","line":9999,"message":"Possible nil dereference at the end of the file."}
]}'
: > "$REPO/m_dpair.env"
orun downgraded_pair.json dpair.md m_dpair.env > /dev/null
check "two downgraded findings at different lines are still two" \
  '2' "$(grep -c '^- ⚠️ \*\*RISK\*\*' "$REPO/dpair.md")"
check "zeroing the rendered line does not make them duplicates" \
  '0' "$(metric_of "$REPO/m_dpair.env" REVIEW_DUPLICATES)"

# Two repo-wide findings share the empty path, so only the message tells
# them apart.
jf wide2.json '{"findings":[
{"severity":"BLOCKER","path":"","line":0,"message":"The workflow grants write permission across every job."},
{"severity":"BLOCKER","path":"","line":0,"message":"The workflow grants write permission to the token by default."}
]}'
: > "$REPO/m_wide2.env"
orun wide2.json wide2.md m_wide2.env > /dev/null
check "two repo-wide findings are not collapsed into one" \
  '2' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `-`' "$REPO/wide2.md")"

# DE-DUPLICATION MUST NEVER EMPTY THE LIST. Three copies of one claim
# collapse to ONE, never to none, and the comment must not become a clean
# verdict -- which is the shape every other mechanism here exists to prevent.
jf triple.json '{"findings":[
{"severity":"BLOCKER","path":"README.md","line":0,"message":"The README publishes an AWS account identifier."},
{"severity":"BLOCKER","path":"README.md","line":0,"message":"The README publishes an AWS account identifier"},
{"severity":"BLOCKER","path":"README.md","line":0,"message":"THE README PUBLISHES AN AWS ACCOUNT IDENTIFIER."}
]}'
: > "$REPO/m_triple.env"
orun triple.json triple.md m_triple.env --summary '4 files, +41/-0.' > /dev/null
check "three copies of one claim collapse to exactly one" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\*' "$REPO/triple.md")"
check "two collapses are counted, not three" \
  '2' "$(metric_of "$REPO/m_triple.env" REVIEW_DUPLICATES)"
check "and the comment is not a clean verdict" \
  '0' "$(grep -c 'No blocking findings' "$REPO/triple.md" || true)"

# ---------------------------------------------------------------------------
# Mechanism 10 -- a finding that disclaims itself is padding
# ---------------------------------------------------------------------------
#
# Verbatim from #340: a blocking marker whose own text says there is nothing
# to flag. The second line is the shape the pattern must NOT eat -- a real
# finding whose sentence is built on a negation.
jf disclaim.json '{"findings":[
{"severity":"BLOCKER","path":"README.md","line":0,"message":"The PR does not touch .claude/CLAUDE.md, so there is nothing to flag there."},
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"This does not validate the input, so a malformed ARN is accepted."}
]}'
: > "$REPO/m_disclaim.env"
orun disclaim.json disclaim.md m_disclaim.env > /dev/null
# Grepped on the finding's own wording, not on the phrase "nothing to
# flag" -- the drop row below contains that phrase itself, so the obvious
# assertion would pass on the row and prove nothing about the finding.
check "a finding whose text says there is nothing to flag is dropped" \
  '0' "$(grep -c '^- \*\*.*does not touch' "$REPO/disclaim.md" || true)"
check "it is counted under its own reason code" \
  '1' "$(metric_of "$REPO/m_disclaim.env" REVIEW_SELF_DISCLAIMED)"
check "and the drop reaches the pull request with that reason" \
  '1' "$(grep -c "^1 self-disclaiming (its own text says there is nothing to flag)$" "$REPO/disclaim.md")"
check "a real finding built on a negation is not eaten with it" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/auth.go:12` — This does not validate the input' "$REPO/disclaim.md")"
check "so exactly one of the pair survives" \
  '1' "$(metric_of "$REPO/m_disclaim.env" REVIEW_FINDINGS)"

# The generic verbs describe CODE as readily as they describe a review, and
# the unscoped pattern ate a real finding built on one. Scoped now: the
# sentence has to end there or say it is about the review.
jf disclaim2.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"The retry loop has nothing to change between attempts, so it spins forever."},
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"I read the whole file and there is nothing to fix."}
]}'
: > "$REPO/m_disclaim2.env"
orun disclaim2.json disclaim2.md m_disclaim2.env > /dev/null
check "a finding whose subject is the code keeps its generic verb" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/auth.go:12` — The retry loop has nothing to change' "$REPO/disclaim2.md")"
check "the same verb about the review is still dropped" \
  '0' "$(grep -c 'I read the whole file' "$REPO/disclaim2.md" || true)"
check "exactly one of that pair survives too" \
  '1' "$(metric_of "$REPO/m_disclaim2.env" REVIEW_FINDINGS)"
check "and exactly one is counted self-disclaiming" \
  '1' "$(metric_of "$REPO/m_disclaim2.env" REVIEW_SELF_DISCLAIMED)"

# ---------------------------------------------------------------------------
# Mechanism 11 -- an anchor that cannot be checked is not one that failed
# ---------------------------------------------------------------------------
#
# The workflow reverts `.claude`, `CLAUDE.md`, `.ripgreprc`, `.gitmodules`
# and `.husky` to the merge base AFTER the manifest is written. At those
# paths the working tree holds the base's file, so `line_count` measures
# content the reviewer was never shown and mechanism 4 silently demoted
# every real finding about them to a RISK.
#
# `.claude/agents/x.md` is in this manifest and NOT in the checkout, so the
# line resolves nowhere -- which is the only condition under which the
# downgrade fires at all.
{
  printf 'modified\t4\t.claude/agents/x.md\tpr-files/0004.patch\n'
  printf 'modified\t4\t.claude-local/x.md\tpr-files/0005.patch\n'
} > "$REPO/restored.tsv"
jf restored.json '{"findings":[
{"severity":"BLOCKER","path":".claude/agents/x.md","line":40,"message":"The agent is given write access to the release branch. Remove it."}
]}'

rrun() { # rrun <out> <metrics> [extra args...] -> stdout, against restored.tsv
  ROUT="$1"
  RMETRICS="$2"
  shift 2
  ( cd "$REPO" && python3 "$SCRIPT" --findings restored.json \
      --manifest restored.tsv --base "$BASE" --out "$ROUT" --head abc \
      --lane B --metrics "$RMETRICS" --coverage-read 2 --coverage-total 2 "$@" )
}

# The control FIRST, so the fixture proves the flag is what changes the
# answer rather than asserting the outcome it wants.
: > "$REPO/m_norestore.env"
rrun norestore.md m_norestore.env > /dev/null
check "without --restored the finding is demoted, which is the defect" \
  '1' "$(grep -c '^- ⚠️ \*\*RISK\*\* `\.claude/agents/x\.md` ' "$REPO/norestore.md")"

: > "$REPO/m_restored.env"
rrun restored.md m_restored.env \
  --restored '.claude CLAUDE.md .ripgreprc .gitmodules .husky' > /dev/null
check "a finding in a restored path keeps BLOCKER" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `\.claude/agents/x\.md:40` ' "$REPO/restored.md")"
check "and is not counted as an unresolvable anchor" \
  '0' "$(metric_of "$REPO/m_restored.env" REVIEW_ANCHOR_DOWNGRADED)"
check "the unchecked anchor is counted instead" \
  '1' "$(metric_of "$REPO/m_restored.env" REVIEW_ANCHOR_UNVERIFIED)"
check "and said so on the pull request rather than left looking checked" \
  '1' "$(grep -c '^\*\*Anchors not checked\*\*$' "$REPO/restored.md")"
check "the disclosure reads as a sentence, singular and plural alike" \
  '1' "$(grep -c '^1 finding cites a path reverted to base content' "$REPO/restored.md")"

# Segment-wise, the same test the coverage side makes: `.claude-local` is
# not under `.claude`, so its anchor is checked and its finding demoted.
jf near.json '{"findings":[
{"severity":"BLOCKER","path":".claude-local/x.md","line":40,"message":"The agent is given write access to the release branch. Remove it."}
]}'
: > "$REPO/m_near.env"
( cd "$REPO" && python3 "$SCRIPT" --findings near.json --manifest restored.tsv \
  --base "$BASE" --out near.md --head abc --lane B --metrics m_near.env \
  --coverage-read 2 --coverage-total 2 --restored '.claude CLAUDE.md' > /dev/null )
check "a path that merely starts with a restored name is still checked" \
  '1' "$(metric_of "$REPO/m_near.env" REVIEW_ANCHOR_DOWNGRADED)"
check "and nothing about it is left unchecked" \
  '0' "$(metric_of "$REPO/m_near.env" REVIEW_ANCHOR_UNVERIFIED)"

# ---------------------------------------------------------------------------
# A corrupt manifest is fatal rather than silently accepted
# ---------------------------------------------------------------------------
#
# A row with fewer than four fields is a file that would silently leave the
# denominator, which is the exact failure the manifest exists to prevent.
printf 'modified\t2\n' > "$REPO/bad.tsv"
set +e
( cd "$REPO" && python3 "$SCRIPT" --findings clean.json --manifest bad.tsv \
  --base "$BASE" --out bad.md ) > /dev/null 2>&1
BAD_STATUS=$?
set -e
check "a corrupt manifest is fatal rather than silently accepted" \
  '1' "$([ "$BAD_STATUS" -ne 0 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# Mechanism 13 -- the commit under review is RENDERED, not only marked
# ---------------------------------------------------------------------------
#
# The comment is EDITED IN PLACE on every push, and GitHub renders an edited
# comment at its ORIGINAL creation position and timestamp. Measured
# 2026-10-29: a live review, updated at 16:13, displayed to every reader as
# a comment dated sixteen days earlier -- and the commit it described was
# recorded only inside the state marker, which is an HTML comment and
# therefore invisible to every human reading the thread. "It doesn't look
# tied to a commit" was exactly right.

ANCHOR_SHA=0123456789abcdef0123456789abcdef01234567
( cd "$REPO" && python3 "$SCRIPT" --findings main.json --manifest manifest.tsv \
  --base "$BASE" --out anchored.md --head "$ANCHOR_SHA" --lane B \
  --coverage-read 3 --coverage-total 4 > /dev/null )
check "the rendered body names the commit the review describes" \
  '1' "$(grep -c '^Reviewed `0123456` at ' "$REPO/anchored.md")"
check "the anchor carries a UTC timestamp to the minute" \
  '1' "$(grep -c '^Reviewed `[0-9a-f]\{7\}` at [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\} UTC\.$' \
    "$REPO/anchored.md")"

# ONE SOURCE, TWO RENDERINGS. If the visible line and the marker could be
# resolved separately they could disagree, and the invisible one is the one
# that would stay right.
ANCHOR_VISIBLE=$(sed -n 's/^Reviewed .*`\([0-9a-f]*\)`.* at .*/\1/p' "$REPO/anchored.md")
ANCHOR_MARKED=$(sed -n 's/.*head=\([0-9a-f]*\) -->.*/\1/p' "$REPO/anchored.md")
check "the visible commit is the marker's head, truncated to seven" \
  '0123456 0123456' \
  "$ANCHOR_VISIBLE $(printf '%s' "$ANCHOR_MARKED" | cut -c1-7)"

# Directly beneath the headline, not at the foot: it answers the first
# question a reader of an edited comment has, and an answer below five
# findings and three disclosure sections is one they reach after deciding
# whether to trust them.
check "the anchor sits directly beneath the headline" \
  '1' "$(sed -n '5p' "$REPO/anchored.md" | grep -c '^Reviewed ')"

# The thin clean review is the one most likely to be mistaken for an old
# comment, because it says the least.
( cd "$REPO" && python3 "$SCRIPT" --findings clean.json --manifest manifest.tsv \
  --base "$BASE" --out anchored_clean.md --head "$ANCHOR_SHA" --lane B \
  --coverage-read 4 --coverage-total 4 > /dev/null )
check "a clean verdict is anchored to its commit too" \
  '1' "$(grep -c '^Reviewed `0123456` at ' "$REPO/anchored_clean.md")"

# THE LINK IS AN ADDITION, NEVER A SUBSTITUTION. `GITHUB_REPOSITORY` is the
# runner's own value and nothing plumbs it, so the line has to render
# correctly with it, without it, and with a value that is not a repository.
( cd "$REPO" && GITHUB_REPOSITORY=senzing-factory/build-resources python3 "$SCRIPT" \
  --findings clean.json --manifest manifest.tsv \
  --base "$BASE" --out anchored_link.md --head "$ANCHOR_SHA" --lane B \
  --coverage-read 4 --coverage-total 4 > /dev/null )
check "the commit links to itself when the runner named the repository" \
  '1' "$(grep -c '^Reviewed \[`0123456`\](https://github.com/senzing-factory/build-resources/commit/0123456789abcdef0123456789abcdef01234567) at ' \
    "$REPO/anchored_link.md")"
# Its own run with the variable explicitly empty, rather than a reread of
# `anchored_clean.md`: the subject of this assertion IS the absence, so it
# must not be the one case that depends on the environment the suite happens
# to have been started in.
( cd "$REPO" && GITHUB_REPOSITORY='' python3 "$SCRIPT" \
  --findings clean.json --manifest manifest.tsv \
  --base "$BASE" --out anchored_plain.md --head "$ANCHOR_SHA" --lane B \
  --coverage-read 4 --coverage-total 4 > /dev/null )
check "and with no repository the same line renders unlinked" \
  '1' "$(grep -c '^Reviewed `0123456` at ' "$REPO/anchored_plain.md")"

# A value that is not `owner/repo` must lose the link, not reach the markdown.
( cd "$REPO" && GITHUB_REPOSITORY='x)](javascript:alert(1)' python3 "$SCRIPT" \
  --findings clean.json --manifest manifest.tsv \
  --base "$BASE" --out anchored_bad.md --head "$ANCHOR_SHA" --lane B \
  --coverage-read 4 --coverage-total 4 > /dev/null )
check "a repository value of the wrong shape is refused the link" \
  '1' "$(grep -c '^Reviewed `0123456` at ' "$REPO/anchored_bad.md")"

# `--head` is not always a SHA: it defaults to the literal `unknown`, and a
# link built from that would 404 while looking authoritative.
( cd "$REPO" && GITHUB_REPOSITORY=senzing-factory/build-resources python3 "$SCRIPT" \
  --findings clean.json --manifest manifest.tsv \
  --base "$BASE" --out anchored_nohead.md --lane B \
  --coverage-read 4 --coverage-total 4 > /dev/null )
check "a head that is not a SHA is not linked" \
  '1' "$(grep -c '^Reviewed `unknown` at ' "$REPO/anchored_nohead.md")"

# ---------------------------------------------------------------------------
# Mechanism 14 -- a disagreement between two pieces of prose is not a finding
# ---------------------------------------------------------------------------
#
# A measured message, 2026-10-29, and it was the WHOLE review. Two code
# comments disagreeing: nothing executes them, no behaviour changes, no
# control stops holding, no permission widens, and the only thing either can
# be fixed with is more prose. There is no severity under which that is a
# finding, so a lower tier that still prints does not answer it.

jf prose.json '{"findings":[
{"severity":"RISK","path":"src/auth.go","line":12,"message":"The boundary comment on <resource> (and the one near line 40) still says the deploy role reads the init report after deploy, which this PR marks SUPERSEDED at line 55, so the comments now contradict each other; add a one-line superseded note to both."}
]}'
: > "$REPO/m_prose.env"
PROSE_LOG=$(orun prose.json prose.md m_prose.env)
check "a comment contradicting another comment reaches nobody" \
  '0' "$(metric_of "$REPO/m_prose.env" REVIEW_FINDINGS)"
check "and the drop is counted" \
  '1' "$(metric_of "$REPO/m_prose.env" REVIEW_PROSE_REJECTED)"

# THE ONE EXCEPTION TO MECHANISM 7, and the reason for it. Every other
# rejection class is disclosed on the pull request, because every other one
# might have been a finding. This one was never a finding, so disclosing it
# posts "1 finding dropped before posting" over a pull request whose correct
# output is the clean verdict -- which reads as the reviewer concealing
# something, and is the complaint the whole mechanism answers.
check "nothing on the pull request says a finding was dropped" \
  '0' "$(grep -c 'Findings dropped before posting' "$REPO/prose.md" || true)"
check "and the rejection's wording is nowhere in the comment" \
  '0' "$(grep -c 'prose-only' "$REPO/prose.md" || true)"

# INVISIBLE TO THE PULL REQUEST, NOT INVISIBLE. This is the ONLY channel the
# drop has, so it carries the message IN FULL and as an annotation: the
# 120-character truncation every other class uses cut the measured BLOCKER
# mid-clause at "...whether the token is", losing the half that proved the
# drop was wrong.
check "the job log names the rejection as an annotation" \
  '1' "$(printf '%s\n' "$PROSE_LOG" | grep -c '^::warning::prose-only disagreement rejected')"
check "and carries the whole message, not a truncation" \
  '1' "$(printf '%s\n' "$PROSE_LOG" | grep -c 'add a one-line superseded note to both\.$')"
check "and the summary line still counts it" \
  '1' "$(printf '%s\n' "$PROSE_LOG" | grep -c '1 prose-only disagreement(s) dropped')"

# The marker is an HTML comment, parsed by `previous_stats` and read by no
# human, so it loses nothing: `dropped=` stays the complete count. That is
# why the byte-identity below is asserted over the body WITHOUT its marker
# line -- the rendered comment is identical, the machine record is not, and
# both of those are deliberate.
check "the marker still records the drop for tooling" \
  '1' "$(grep -c 'findings=0 blockers=0 dropped=1 read=4/4 ' "$REPO/prose.md")"

# A PULL REQUEST WHOSE ONLY FINDING WAS A PROSE-ONLY DROP IS A CLEAN ONE.
# Not nearly clean, not clean with a footnote: the same bytes, denominator
# and all, as a run that produced no findings at all.
jf prose_none.json '{"findings":[]}'
: > "$REPO/m_prose2.env"
orun prose_none.json prose_none.md m_prose2.env > /dev/null
sed '/^<!-- claude-review /d' "$REPO/prose.md" > "$REPO/prose.visible"
sed '/^<!-- claude-review /d' "$REPO/prose_none.md" > "$REPO/prose_none.visible"
check "the rendered comment is byte-identical to one with no findings at all" \
  'same' \
  "$(cmp -s "$REPO/prose.visible" "$REPO/prose_none.visible" && echo same || echo differs)"
check "and that comment is the ordinary clean verdict with its denominator" \
  '1' "$(grep -c '^✅ \*\*No blocking findings in the 4 of 4 files opened\.\*\*$' \
    "$REPO/prose.visible")"

# DO NOT GENERALISE THIS. Every other drop class keeps its disclosure, and
# `solo_pad` above is the live proof for padding; this re-asserts it beside
# the exception so the two cannot be confused when one of them is edited.
check "another drop class is still disclosed on the pull request" \
  '1' "$(grep -c 'Findings dropped before posting' "$REPO/solo_pad.md")"

# THE BOUNDARY, and it is the half that matters: this branch DROPS, so a
# wrong match deletes a real finding where nobody can see it went.
#
# THE FIRST FOUR ARE THE SHAPE MEASURED DELETED -- documentation against
# code, README against workflow, comment against implementation, docstring
# against signature. Every one says `contradict each other`, which an
# earlier version of this rule accepted as the second party; `each other`
# names nothing, so only the left side was ever checked, and the first of
# these went out as REVIEW_FINDINGS=0 and a clean verdict while naming an
# open admin route. The last two name the code, and a dead knob an operator
# is told to set.
jf prose_keep.json '{"findings":[
{"severity":"RISK","path":"src/auth.go","line":12,"message":"The documentation and the code contradict each other about whether the token is validated: the docs say every request is checked, the handler skips validation when the header is absent, so a caller with no token reaches the admin route."},
{"severity":"RISK","path":"src/auth.go","line":13,"message":"The README and the workflow contradict each other about which branch publishes, so a release cut from main never reaches the registry."},
{"severity":"RISK","path":"src/auth.go","line":14,"message":"The comment and the implementation contradict each other about the lock ordering, and the implementation is the one that deadlocks."},
{"severity":"RISK","path":"src/new.go","line":1,"message":"The docstring and the signature contradict each other: the docstring says the timeout is seconds, the parameter is milliseconds."},
{"severity":"RISK","path":"README.md","line":1,"message":"The runbook tells the on-call to set INIT_BUDGET_MS, which the image no longer reads, so the documented recovery step does nothing. Remove it."}
]}'
: > "$REPO/m_prose3.env"
orun prose_keep.json prose_keep.md m_prose3.env > /dev/null
# FIVE, not six: FINDING_LIMIT is 5, so a sixth would be withheld for space
# and this assertion would be measuring the cap instead of the rule.
check "every docs-against-code finding survives the prose rule" \
  '5' "$(metric_of "$REPO/m_prose3.env" REVIEW_FINDINGS)"
check "and not one of them was taken for a prose-only disagreement" \
  '0' "$(metric_of "$REPO/m_prose3.env" REVIEW_PROSE_REJECTED)"

# Two more that must survive, in their own file to stay under the cap.
#
# A prose noun on the FAR SIDE of a second party is not the second party:
# "the comment says the retry count is 3 but the loop runs 5 times, which
# contradicts the documentation" is a finding about the LOOP, and reading
# across the comma to `documentation` deleted it.
#
# And the repo-wide spelling, which reaches the prose rule before the
# empty-path shortcut and so has to be tested there rather than assumed.
jf prose_across.json '{"findings":[
{"severity":"RISK","path":"src/auth.go","line":15,"message":"The comment says the retry count is 3 but the loop runs 5 times, which contradicts the documentation."},
{"severity":"RISK","path":"","line":0,"message":"The documentation contradicts the behaviour this change ships: the install command points at a branch that no longer exists. Update it."}
]}'
: > "$REPO/m_prose5.env"
orun prose_across.json prose_across.md m_prose5.env > /dev/null
check "the rule does not read across a clause to find its second party" \
  '2' "$(metric_of "$REPO/m_prose5.env" REVIEW_FINDINGS)"
check "and a repo-wide prose finding is judged, not skipped" \
  '0' "$(metric_of "$REPO/m_prose5.env" REVIEW_PROSE_REJECTED)"

# THE SEVERITY FLOOR, which is defence in depth and not the fix: a sentence
# this rule WOULD drop keeps its finding when the model called it a BLOCKER.
# The two errors are not symmetrical -- a prose nit called a BLOCKER is one
# visible line somebody can argue with, a real BLOCKER deleted by a regex is
# invisible. The message is the verbatim drop case above, which the
# assertions at the top of this block prove the rule matches.
jf prose_floor.json '{"findings":[
{"severity":"BLOCKER","path":"src/auth.go","line":12,"message":"The boundary comment on <resource> (and the one near line 40) still says the deploy role reads the init report after deploy, which this PR marks SUPERSEDED at line 55, so the comments now contradict each other; add a one-line superseded note to both."}
]}'
: > "$REPO/m_prose4.env"
orun prose_floor.json prose_floor.md m_prose4.env > /dev/null
check "a BLOCKER is never dropped as prose, whatever the sentence says" \
  '1' "$(metric_of "$REPO/m_prose4.env" REVIEW_BLOCKERS)"
check "and the prose rule records no drop for it" \
  '0' "$(metric_of "$REPO/m_prose4.env" REVIEW_PROSE_REJECTED)"

# ---------------------------------------------------------------------------
# Mechanism 15 -- a severity marker per finding, and NOT a tick per check
# ---------------------------------------------------------------------------
#
# The 4.8.0 work removed the per-check tick lines because they were filler:
# 29 to 32 of them in one measured pair of reviews, each restating that
# something was fine, none of them actionable. Sorting a comment into issues
# and non-issues at a glance is a DIFFERENT need, and it is answered by one
# character on a line that already exists rather than by a line of its own.
#
# The assertions throughout this file already pin the exact rendered form of
# every bullet. What this block adds is the property that cannot be read off
# any single one of them: that the markers did not bring the filler back.

( cd "$REPO" && python3 "$SCRIPT" --findings main.json --manifest manifest.tsv \
  --base "$BASE" --out marks.md --head "$ANCHOR_SHA" --lane B \
  --coverage-read 3 --coverage-total 4 > /dev/null )

# ONE MARKER PER FINDING, AND NO LINE OF ITS OWN: as many marked bullets as
# there are bullets, so no finding is unmarked and no marker arrived on a
# line that is not a finding.
check "every finding bullet carries a severity marker" \
  "$(grep -c '^- ' "$REPO/marks.md")" \
  "$(grep -cE '^- (❌|⚠️) \*\*(BLOCKER|RISK)\*\* ' "$REPO/marks.md")"

# THE SEVERITY WORD SURVIVES BESIDE THE MARKER. It is what a screen reader
# announces and what `rg '\*\*BLOCKER\*\*'` matches; the marker is for the
# eye. A marker that REPLACED the word would pass a scanning test and lose
# both of those readers.
check "and the severity word beside it, for grep and for a screen reader" \
  '1' "$(grep -c '^- ❌ \*\*BLOCKER\*\* `src/auth.go:12`' "$REPO/marks.md")"

# THE FILLER REGRESSION, which is the one worth a standing guard. A tick is
# the CLEAN VERDICT's marker and nothing else: a body carrying findings must
# not carry one anywhere, or the per-check ticks are back by another route.
check "no tick appears anywhere in a comment that has findings" \
  '0' "$(grep -c '✅' "$REPO/marks.md")"

# And the converse: the clean verdict is marked, so "nothing to do here" is
# as scannable as a blocker is.
check "the clean verdict carries the tick" \
  '1' "$(grep -c '^✅ \*\*No blocking findings' "$REPO/clean.md")"

# A clean verdict is not a finding, so it must not carry a severity marker.
check "and no severity marker" \
  '0' "$(grep -cE '❌|⚠' "$REPO/clean.md")"

# ---------------------------------------------------------------------------
# review-note -- the wrapper that gives the scratchpad somewhere to be
# ---------------------------------------------------------------------------
#
# A wrapper rather than an allowed command prefix, because `Bash(cmd:*)`
# bounds the start of the command string and nothing after it. These
# assertions are what "the wrapper validates its own arguments" has to mean
# in practice: argv reaches one printf as data, and the destination comes
# from the environment so no argument can redirect the write.

NOTE="$HERE/review-note"

check "a note is appended to the file named by the environment" \
  'checked the pin table' \
  "$(REVIEW_NOTES="$WORK/n.txt" "$NOTE" checked the pin table > /dev/null; \
    cat "$WORK/n.txt")"
check "a second note appends rather than replacing" \
  '2' "$(REVIEW_NOTES="$WORK/n.txt" "$NOTE" second note > /dev/null; \
    wc -l < "$WORK/n.txt" | tr -d ' ')"
check "an unset destination is refused rather than guessed" \
  '2' "$(unset REVIEW_NOTES; "$NOTE" anything > /dev/null 2>&1; echo $?)"
check "a note with no text is refused" \
  '2' "$(REVIEW_NOTES="$WORK/n.txt" "$NOTE" > /dev/null 2>&1; echo $?)"

# Shell metacharacters in the note are DATA. If argv were ever interpreted,
# this is the shape that would show it.
check "shell metacharacters in a note are written literally" \
  '1' "$(REVIEW_NOTES="$WORK/meta.txt" "$NOTE" 'x; rm -rf /; $(id) `id` && y' \
    > /dev/null; grep -c 'x; rm -rf /; \$(id) `id` && y' "$WORK/meta.txt")"
check "and nothing else was created by writing it" \
  '1' "$(wc -l < "$WORK/meta.txt" | tr -d ' ')"

# Bounded, so a loop cannot fill the runner's disk.
check "an over-long note is refused" \
  '2' "$(REVIEW_NOTES="$WORK/n.txt" "$NOTE" "$(rep 600 z)" > /dev/null 2>&1; echo $?)"
check "a full notes file refuses further notes" \
  '2' "$(rep 70000 q > "$WORK/full.txt"; \
    REVIEW_NOTES="$WORK/full.txt" "$NOTE" more > /dev/null 2>&1; echo $?)"

check "review-note --help prints its own header comment" \
  '1' "$("$NOTE" --help | grep -c '^Usage:  review-note <text\.\.\.>$')"

if [ "$FAILED" -eq 0 ]; then
  echo "all review_output.py tests passed"
else
  echo "review_output.py tests FAILED" >&2
fi
exit "$FAILED"
