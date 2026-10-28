#!/usr/bin/env bash
# cspell:ignore BIGBODY cacheinfo drun erun mrun newpkg oldpkg superproject  -- test fixture / local constant names, not vocabulary
# Fixture tests for filter_diff.py. No framework: builds the two input shapes
# the program accepts, runs it, and checks what survived.
#
# Part 1 covers --manifest, the mode the workflow runs: the JSON of
# `gh api repos/{o}/{r}/pulls/{n}/files --paginate` in, a manifest plus one
# patch file per surviving path out. Part 2 covers the unified-diff fallback
# used by a local `git diff` invocation.
#
# Why these fixtures: every one of them was a real defect. A quoted non-ASCII
# binary path has no "+++" line and no " b/" in its header, so it silently
# escaped the globs that exist to drop it. A deletion's "+++" is /dev/null. A
# rename must match on the NEW path -- both the `similarity index` form with no
# ---/+++ lines (header fallback) and the content-changing form that has them,
# which is the only fixture that pins the "+++ over ---" preference. The diff
# must survive byte-identically both when nothing is excluded and when
# something is, so a latin-1 source file is not rewritten with U+FFFD. A POSIX
# locale used to crash mid-write. CRLF line endings must survive, or
# line-ending changes are invisible to the reviewer.
#
# Assertions check the dropped-path LIST, not just the count: a count-only
# assertion still passes when the wrong file is the one that got dropped.
#
# Parts 1c to 1e are the `git cat-file --batch` stream: a gitlink whose body
# must be drained, a deletion sniffed from its pre-image, and a stream that
# ends or exits non-zero mid-set -- all three the same failure, a verdict
# attributed to the wrong object or to none, which surfaces as a forged
# attribute conflict against a file the reviewer is then told not to open.
#
# Part 1b is a second repository whose paths are hostile on purpose: they
# carry a newline or a tab, and the newline spells a forged copy of a line the
# workflow parses out of this program's own log. Nothing in those paths may
# reach the log or the manifest unescaped.
#
# --discussion moved to pr_discussion.py and its fixtures to
# test_pr_discussion.sh; the "Part 3" this comment used to describe is not in
# this file.
#
# Usage:  ./test_filter_diff.sh        # from anywhere; exits non-zero on failure
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/filter_diff.py"
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

# ----------------------------------------------------------------------------
# Part 1 -- --manifest mode, against a real repository
# ----------------------------------------------------------------------------
#
# These fixtures are a REAL GIT REPOSITORY rather than a JSON response,
# because the manifest is now computed from git plumbing and the JSON is only
# a witness. Building the repository is what makes the interesting cases
# testable at all: a blob whose content is binary, a `.gitattributes` entry
# that lies about one, a mode-only change, a pure rename, and paths with a
# space, non-ASCII bytes and a newline in them.
#
# Every one of these was a real defect. A quoted non-ASCII path has no "+++"
# line and no " b/" in its header, so it escaped the globs meant to drop it.
# A deletion's "+++" is /dev/null. A rename must match on the NEW path. A
# mode-only change and a pure rename have no "@@" hunk and were discarded as
# "no diff could be rendered", sending the reviewer to open a working-tree
# file whose bytes are identical. And a newline in a path injected a second
# count line into the log the workflow parses.

REPO="$WORK/repo"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q .
  git config user.email fixture@example.invalid
  git config user.name Fixture
  git config commit.gpgsign false

  mkdir -p pkg oldpkg scripts src moved
  printf 'v1.2.3\n' > pkg/real.go
  printf 'lockfile\n' > yarn.lock
  printf '\000\001\002binary\000' > logo.png
  printf 'package oldpkg\n' > oldpkg/mod.go
  for i in 1 2 3 4 5 6 7 8 9 10; do printf 'func f%s() {}\n' "$i" >> oldpkg/mod.go; done
  printf 'to be deleted\n' > gone.txt
  printf '#!/bin/sh\necho hi\n' > scripts/run.sh
  printf 'space\n' > 'src/with space.go'
  ACCENTED="src/$(printf 'caf\303\251') note.go"
  printf 'accented\n' > "$ACCENTED"
  printf 'unchanged content\n' > moved/old.txt
  printf 'guarded\n' > src/auth.go
  # Twelve kilobytes, so it is reliably the largest patch and the byte
  # budget has an unambiguous largest-first victim to drop.
  head -c 12000 /dev/zero | tr '\000' 'A' > big.txt
  printf '\n' >> big.txt
  git add -A
  git commit -qm base
  git rev-parse HEAD > "$WORK/base.sha"

  printf 'v1.2.4\n' > pkg/real.go
  printf 'lockfile changed\n' > yarn.lock
  printf '\000\003\004other\000' > logo.png
  git mv oldpkg/mod.go newpkg/mod.go 2> /dev/null || {
    mkdir -p newpkg
    git mv oldpkg/mod.go newpkg/mod.go
  }
  sed -i '1s/.*/package newpkg/' newpkg/mod.go
  git mv moved/old.txt moved/new.txt
  git rm -q gone.txt
  chmod +x scripts/run.sh
  printf 'space changed\n' > 'src/with space.go'
  printf 'accented changed\n' > "src/$(printf 'caf\303\251') note.go"
  printf 'guarded\nnewly added line\n' > src/auth.go
  # THE ATTACK. One line marking a source file as having no diff. git then
  # reports it as "Binary files ... differ" whatever its content, and a
  # reviewer told a file is binary is a reviewer told not to open it.
  printf 'src/auth.go -diff\n' > .gitattributes
  head -c 12000 /dev/zero | tr '\000' 'B' > big.txt
  printf '\n' >> big.txt
  printf 'two\n' > "$(printf 'odd\nname.txt')"
  git add -A
  git commit -qm change
  git rev-parse HEAD > "$WORK/head.sha"
) > /dev/null

BASE=$(cat "$WORK/base.sha")
HEAD=$(cat "$WORK/head.sha")

# The path set git sees, as `pulls/{n}/files` would report it. Used only as
# the cross-check witness.
printf '%s\n' '[' \
  '{"filename":".gitattributes"},' \
  '{"filename":"big.txt"},' \
  '{"filename":"logo.png"},' \
  '{"filename":"moved/new.txt","previous_filename":"moved/old.txt"},' \
  '{"filename":"newpkg/mod.go","previous_filename":"oldpkg/mod.go"},' \
  '{"filename":"odd\nname.txt"},' \
  '{"filename":"gone.txt"},' \
  '{"filename":"pkg/real.go"},' \
  '{"filename":"scripts/run.sh"},' \
  '{"filename":"src/auth.go"},' \
  '{"filename":"src/café note.go"},' \
  '{"filename":"src/with space.go"},' \
  '{"filename":"yarn.lock"}' \
  ']' > "$WORK/files.json"

# Same, minus one path, to prove the cross-check fails rather than papers
# over a disagreement about the denominator.
grep -v '"big.txt"' "$WORK/files.json" > "$WORK/files_short.json"

mrun() { # mrun <out_dir> <budget> [files_json] -> the program's stdout
  ( cd "$REPO" && EXCLUDE_GLOBS="$GLOBS" MAX_REVIEW_BYTES="$2" \
      python3 "$SCRIPT" --manifest "$1" "$BASE" "$HEAD" ${3:+"$3"} )
}

manifest_of() { # manifest_of <out_dir> -> the manifest's contents
  cat "$REPO/$1/manifest.tsv"
}

field_of() { # field_of <log> <label> -> the value after "<label>: "
  printf '%s\n' "$1" | sed -n "s/^$2: //p"
}

GLOBS='*.lock
vendor/*'

echo "filter_diff.py --manifest"

# The attributes defence the workflow writes. Everything after this point is
# measured WITH it in place, because that is how the workflow runs; the one
# case measured without it is the attack, below.
mkdir -p "$REPO/.git/info"
printf '%s\n' '* !diff' >> "$REPO/.git/info/attributes"

LOG=$(mrun out "0" "$WORK/files.json")

check "exclude_globs drops the lockfile and only the lockfile" \
  'yarn.lock' "$(printf '%s\n' "$LOG" | sed -n 's/^  - //p')"
check "the surviving file count is reported" \
  '12' "$(field_of "$LOG" 'Files')"
# The workflow parses these two into REVIEW_ADDITIONS/REVIEW_DELETIONS and the
# prompt adds them to pick the review's lane, so a sum over the wrong set
# silently picks the wrong lane. Summed over the SURVIVING records only: the
# 1/1 of the excluded yarn.lock is not in either figure, and logo.png, which
# git will not line-count, contributes 0 rather than breaking the sum.
check "additions are summed over surviving files only" \
  '8' "$(field_of "$LOG" 'Additions')"
check "deletions are summed over surviving files only" \
  '6' "$(field_of "$LOG" 'Deletions')"
check "nothing is omitted when the budget is unlimited" \
  '' "$(printf '%s\n' "$LOG" | sed -n 's/^  \* //p')"
check "the cross-check agrees with the files API" \
  '1' "$(printf '%s\n' "$LOG" | grep -c '^Crosscheck: ok,')"
check "the range under review is the one it was given" \
  "$BASE..$HEAD" "$(field_of "$LOG" 'Range')"

# BINARY-NESS FROM THE BLOB. logo.png's content really is binary, so it is
# the one row carrying the token -- and src/auth.go, which `.gitattributes`
# claims is binary, is not.
check "a file whose content is binary is reported as binary" \
  '1' "$(printf '%s\n' "$LOG" | grep -c '^  ~ logo\.png$')"
check "exactly one file is called binary" \
  '1' "$(printf '%s\n' "$LOG" | sed -n 's/^Binary \([0-9][0-9]*\) file(s).*/\1/p')"
check "a -diff attribute does not make a text file binary" \
  '0' "$(manifest_of out | grep -c '^modified	[0-9]*	src/auth\.go	binary$' || true)"
check "and that file gets a real patch instead" \
  '1' "$(manifest_of out | grep -c '^modified	1	src/auth\.go	out/[0-9]*\.patch$')"
check "nothing is left unpatched once the attributes are neutralised" \
  '0' "$(printf '%s\n' "$LOG" | sed -n 's/^Unpatched \([0-9][0-9]*\) file(s).*/\1/p')"

# A mode change and a pure rename have no "@@" hunk at all. Those lines ARE
# the whole change, and discarding them reported a 644 -> 755 file as
# undiffable and sent the reviewer to a working tree where the executable
# bit cannot be seen.
check "a mode-only change keeps its mode lines as its patch" \
  '1' "$(grep -c '^new mode 100755$' \
    "$REPO/$(manifest_of out | awk -F'\t' '$3=="scripts/run.sh"{print $4}')")"
check "a pure rename keeps its rename lines as its patch" \
  '1' "$(grep -c '^rename to moved/new\.txt$' \
    "$REPO/$(manifest_of out | awk -F'\t' '$3=="moved/new.txt"{print $4}')")"
check "a rename is recorded against its NEW path" \
  '1' "$(manifest_of out | grep -c '^renamed	[0-9]*	newpkg/mod\.go	')"
check "a rename is not recorded against its old path" \
  '0' "$(manifest_of out | grep -c 'oldpkg/mod\.go' || true)"
check "a deletion gets a real patch" \
  '1' "$(grep -c '^+++ /dev/null$' \
    "$REPO/$(manifest_of out | awk -F'\t' '$3=="gone.txt"{print $4}')")"

# Paths git has to quote, or that break a line-oriented reader. Each one
# must still reach the manifest with a patch -- an unmatched path falls out
# of the review set silently, which is the whole failure this file guards.
check "a path containing a space gets its own patch" \
  '1' "$(manifest_of out | grep -c '^modified	2	src/with space\.go	out/[0-9]*\.patch$')"
check "a path containing non-ASCII bytes gets its own patch" \
  '1' "$(manifest_of out | grep -cP '^modified\t2\tsrc/caf\xc3\xa9 note\.go\tout/[0-9]*\.patch$')"
check "a newline in a path is escaped onto one manifest row" \
  '1' "$(manifest_of out | grep -c '^added	1	odd\\nname\.txt	out/[0-9]*\.patch$')"
check "a newline in a path cannot inject a second Files count" \
  '1' "$(printf '%s\n' "$LOG" | grep -c '^Files: ')"

# THE CROSS-CHECK IS A GATE, not a note. Two derivations of the denominator
# that disagree mean one of them is wrong, and the coverage figure divides
# by it -- so the run stops rather than reporting a number computed from a
# file list it cannot corroborate.
set +e
MISMATCH=$( ( cd "$REPO" && EXCLUDE_GLOBS="$GLOBS" MAX_REVIEW_BYTES=0 \
  python3 "$SCRIPT" --manifest out_mismatch "$BASE" "$HEAD" \
  "$WORK/files_short.json" ) 2>&1 )
MISMATCH_STATUS=$?
set -e
check "a disagreement with the files API is fatal" '3' "$MISMATCH_STATUS"
check "and it names which side has the extra path" \
  '1' "$(printf '%s\n' "$MISMATCH" | grep -c 'in git and not in the API: big.txt')"

# `gh api --paginate` has emitted one spliced array, several arrays and one
# object per line across versions, which is why review_io.json_values decodes
# values until the input runs out. A gh upgrade that joins pages differently
# would otherwise leave the witness empty, and an empty witness is not a
# degraded cross-check -- it is a MISMATCH, so every review would abort.
python3 -c 'import json, sys
records = json.load(open(sys.argv[1], encoding="utf-8"))
half = len(records) // 2
print(json.dumps(records[:half]))
print(json.dumps(records[half:]))' "$WORK/files.json" > "$WORK/files_pages.json"
# Guarded, because the failure mode under test is the fatal one: a half-read
# witness exits 3, which would take the rest of this file's assertions with
# it instead of naming the one that broke.
set +e
PAGES_LOG=$(mrun out_pages "0" "$WORK/files_pages.json" 2>&1)
set -e
check "concatenated --paginate pages are read as one list" \
  'ok, 15 path(s) agreed with the files API.' \
  "$(field_of "$PAGES_LOG" 'Crosscheck')"

# Without a witness the program says so rather than implying corroboration
# it did not get. A failed API call degrades to this, by design.
LOG=$(mrun out_nocheck "0")
check "with no witness the file list says it has one source" \
  '1' "$(printf '%s\n' "$LOG" | grep -c '^Crosscheck: not performed')"

# THE ATTACK, measured without the defence. src/auth.go must still reach the
# reviewer: no patch, named under Unpatched, and flagged as an attribute
# conflict -- never silently absent and never marked binary.
ATTACK="$WORK/attack"
cp -a "$REPO" "$ATTACK"
rm -f "$ATTACK/.git/info/attributes"
ATTACK_LOG=$( cd "$ATTACK" && EXCLUDE_GLOBS="$GLOBS" MAX_REVIEW_BYTES=0 \
  python3 "$SCRIPT" --manifest out_attack "$BASE" "$HEAD" )
check "an attribute git honoured is reported as a conflict" \
  '1' "$(printf '%s\n' "$ATTACK_LOG" | grep -c '^  @ src/auth\.go$')"
check "the suppressed file is named under Unpatched, not Binary" \
  '1' "$(printf '%s\n' "$ATTACK_LOG" | grep -c '^  ! src/auth\.go$')"
check "the suppressed file is never called binary" \
  '0' "$(printf '%s\n' "$ATTACK_LOG" | grep -c '^  ~ src/auth\.go$' || true)"
check "so the reviewer is still sent to open it" \
  '1' "$(cat "$ATTACK/out_attack/manifest.tsv" | grep -c '^modified	0	src/auth\.go	-$')"

# Over budget, whole patches go largest-first and the row keeps its path and
# change count, so the reviewer still sees that the file changed.
LOG=$(mrun out_budget "2000" "$WORK/files.json")
check "over budget the largest patch is the one dropped" \
  'big.txt' "$(printf '%s\n' "$LOG" | sed -n 's/^  \* //p')"
check "an omitted file keeps its manifest row, marked omitted" \
  '1' "$(manifest_of out_budget | grep -c '^modified	[0-9]*	big\.txt	omitted$')"
check "an omitted patch is not reported as an exclude_globs exclusion" \
  'yarn.lock' "$(printf '%s\n' "$LOG" | sed -n 's/^  - //p')"
check "the surviving patches are still written" \
  '1' "$(manifest_of out_budget | grep -c '^modified	2	pkg/real\.go	out_budget/[0-9]*\.patch$')"

# Writing into a directory the repository already owns would alter the tree
# under review, so the refusal is deliberate and the workflow depends on it.
set +e
( cd "$REPO" && EXCLUDE_GLOBS="$GLOBS" MAX_REVIEW_BYTES=0 \
  python3 "$SCRIPT" --manifest out "$BASE" "$HEAD" ) > /dev/null 2>&1
REUSE_STATUS=$?
set -e
check "writing into an existing output directory is refused" \
  '1' "$([ "$REUSE_STATUS" -ne 0 ] && echo 1 || echo 0)"

# A revision that does not resolve is the reviewer's own breakage, and it
# must be loud: a silent empty manifest reads as "no reviewable changes".
set +e
( cd "$REPO" && EXCLUDE_GLOBS="" MAX_REVIEW_BYTES=0 \
  python3 "$SCRIPT" --manifest out_bad "$BASE" nosuchrev ) > /dev/null 2>&1
BADREV_STATUS=$?
set -e
check "an unresolvable revision exits non-zero" \
  '4' "$BADREV_STATUS"

# ----------------------------------------------------------------------------
# Part 1b -- paths crafted to forge the log lines the workflow parses
# ----------------------------------------------------------------------------
#
# A SECOND repository rather than more paths in the one above, because these
# have to be the excluded file in one run and the over-budget victim in
# another, and the fixture above already has a designated victim in big.txt.
#
# THE DEFECT. git permits a newline in a path, and a path spelling its own
# "Excluded N file(s)." line made the workflow's EXCLUDED_COUNT two lines
# long, so `[ "$EXCLUDED_COUNT" -gt 0 ]` failed with "integer expression
# expected" INSIDE an `if` -- bash -e did not trip, the else branch ran, and
# the posted comment silently lost its whole "files were dropped" disclosure
# with the job still green. Same mechanism for the omission list. A tab is the
# quieter half of the same hazard: unescaped it splits one manifest row into
# five fields and shifts every later column, including the patch token the
# coverage denominator is read from.
#
# Built from real commits rather than a JSON fixture, so the whole
# git --raw -z -> tsv_field chain is what is under test.

EVIL="$WORK/evil"
FORGED_EXCLUDE=$(printf 'evil\nExcluded 9 file(s) from review.\nx.png')
FORGED_OMIT=$(printf 'evil\nOmitted 9 file(s) to fit MAX_REVIEW_BYTES=0.\nbig.go')
TABBED=$(printf 'od\td.go')
mkdir -p "$EVIL"
(
  cd "$EVIL"
  git init -q .
  git config user.email fixture@example.invalid
  git config user.name Fixture
  git config commit.gpgsign false

  printf 'base\n' > keep.go
  git add -A
  git commit -qm base
  git rev-parse HEAD > "$WORK/evil_base.sha"

  printf 'not really an image\n' > "$FORGED_EXCLUDE"
  printf 'small\n' > small.go
  printf 'tabbed\n' > "$TABBED"
  # Twelve kilobytes again, so this path is the unambiguous largest-first
  # victim once a budget applies.
  head -c 12000 /dev/zero | tr '\000' 'A' > "$FORGED_OMIT"
  printf '\n' >> "$FORGED_OMIT"
  git add -A
  git commit -qm forged
  git rev-parse HEAD > "$WORK/evil_head.sha"
) > /dev/null

EVIL_BASE=$(cat "$WORK/evil_base.sha")
EVIL_HEAD=$(cat "$WORK/evil_head.sha")

erun() { # erun <out_dir> <globs> <budget> -> the program's stdout
  ( cd "$EVIL" && EXCLUDE_GLOBS="$2" MAX_REVIEW_BYTES="$3" \
      python3 "$SCRIPT" --manifest "$1" "$EVIL_BASE" "$EVIL_HEAD" )
}

EVIL_LOG=$(erun out_excluded '*.png' 0)
check "a newline in a path cannot inject a second Excluded count" \
  '1' "$(printf '%s\n' "$EVIL_LOG" | grep -c '^Excluded ')"
check "the crafted path is escaped onto a single disclosure line" \
  'evil\nExcluded 9 file(s) from review.\nx.png' \
  "$(printf '%s\n' "$EVIL_LOG" | sed -n 's/^  - //p')"
# Four fields, and the third is the escaped form: a raw tab would make it
# `od` and give the row five.
check "a tab in a path is escaped rather than breaking the row" \
  '4' "$(awk -F'\t' '$3 == "od\\td.go" {print NF}' "$EVIL/out_excluded/manifest.tsv")"

EVIL_LOG=$(erun out_omitted '' 2000)
check "a newline in a path cannot inject a second Omitted count" \
  '1' "$(printf '%s\n' "$EVIL_LOG" | grep -c '^Omitted ')"
check "the crafted path is escaped onto a single omission line" \
  'evil\nOmitted 9 file(s) to fit MAX_REVIEW_BYTES=0.\nbig.go' \
  "$(printf '%s\n' "$EVIL_LOG" | sed -n 's/^  \* //p')"

# ----------------------------------------------------------------------------
# Part 1c -- a gitlink whose commit object lives in the superproject
# ----------------------------------------------------------------------------
#
# THE DEFECT. `sniff_binary` drives one `git cat-file --batch` process and
# must take every answer's body off the pipe to reach the next one. An
# ordinary submodule bump answers `<sha> missing`, which has no body, so
# skipping it was right -- and the same branch also caught `<sha> commit <n>`,
# which HAS one. That happens whenever the superproject already holds the
# commit a gitlink points at: a submodule that is a clone of the same
# repository, or one `git update-index` line. The commit body was then read as
# the next object's header and the stream never recovered, so every object
# sorted after it lost its verdict and fell back to "not binary".
#
# A THIRD repository because the ordering is the whole fixture: the gitlink's
# object id has to sort BEFORE the binary blob's, or the corruption happens
# after the only answer that would show it. The payload is varied until it
# does rather than hard-coded, because a hard-coded blob stops sorting the way
# the test needs the moment anything else about the fixture changes.

GITLINK="$WORK/gitlink"
mkdir -p "$GITLINK"
(
  cd "$GITLINK"
  git init -q .
  git config user.email fixture@example.invalid
  git config user.name Fixture
  git config commit.gpgsign false

  printf 'base\n' > keep.txt
  git add -A
  git commit -qm base
  git rev-parse HEAD > "$WORK/gitlink_base.sha"
  TARGET_COMMIT=$(git rev-parse HEAD)

  TRY=0
  while :; do
    printf '\000\001\002binary\000%s\n' "$TRY" > logo.bin
    if [ "$(git hash-object logo.bin)" \> "$TARGET_COMMIT" ]; then break; fi
    TRY=$((TRY + 1))
    if [ "$TRY" -gt 200 ]; then
      echo "fixture: no blob sorts after $TARGET_COMMIT" >&2
      exit 1
    fi
  done

  # The gitlink points at this repository's own base commit, so the object
  # is present and `cat-file` answers with a body.
  git update-index --add --cacheinfo "160000,$TARGET_COMMIT,sub"
  git add logo.bin
  git commit -qm gitlink
  git rev-parse HEAD > "$WORK/gitlink_head.sha"
) > /dev/null

GL_BASE=$(cat "$WORK/gitlink_base.sha")
GL_HEAD=$(cat "$WORK/gitlink_head.sha")
GL_LOG=$( cd "$GITLINK" && EXCLUDE_GLOBS="" MAX_REVIEW_BYTES=0 \
  python3 "$SCRIPT" --manifest out_gitlink "$GL_BASE" "$GL_HEAD" )

check "a gitlink's commit body does not cost the next object its verdict" \
  '1' "$(printf '%s\n' "$GL_LOG" | grep -c '^  ~ logo\.bin$')"
# The false alarm the broken stream produced: the blob's own content
# never reached the comparison, so git's binary verdict stood alone and read
# as an attribute suppressing a patch -- the one alarm in this program that
# accuses the pull request of an attack.
check "and does not forge an attribute conflict against it" \
  '0' "$(printf '%s\n' "$GL_LOG" | grep -c '^  @ logo\.bin$' || true)"
check "so the binary row is marked binary, not a bare '-'" \
  '1' "$(grep -c '^added	0	logo\.bin	binary$' \
    "$GITLINK/out_gitlink/manifest.tsv")"
check "and the gitlink itself still reaches the manifest with its patch" \
  '1' "$(grep -c '^added	1	sub	out_gitlink/[0-9]*\.patch$' \
    "$GITLINK/out_gitlink/manifest.tsv")"

# ----------------------------------------------------------------------------
# Part 1d -- a deleted binary file
# ----------------------------------------------------------------------------
#
# THE DEFECT. `git diff --raw` ABBREVIATES object names, so a deletion's
# post-image arrives as `0000000` and an equality test against forty zeros
# never matched it. The pre-image blob was therefore never consulted: the
# absent post-image was, it came back with no verdict, and a plain
# `git rm logo.png` was reported as an attribute conflict with a `-` row the
# prompt sends the reviewer to open in a working tree it is not in.
#
# Its own repository rather than a row in the fixture above, because that one
# already pins the file count and the addition and deletion sums that the
# workflow reads to pick the review's lane.

DELETED="$WORK/deleted"
mkdir -p "$DELETED"
(
  cd "$DELETED"
  git init -q .
  git config user.email fixture@example.invalid
  git config user.name Fixture
  git config commit.gpgsign false

  printf 'keep\n' > keep.txt
  printf '\000\001\002binary\000' > gone.bin
  git add -A
  git commit -qm base
  git rev-parse HEAD > "$WORK/deleted_base.sha"

  git rm -q gone.bin
  git commit -qm delete
  git rev-parse HEAD > "$WORK/deleted_head.sha"
) > /dev/null

DEL_BASE=$(cat "$WORK/deleted_base.sha")
DEL_HEAD=$(cat "$WORK/deleted_head.sha")
DEL_LOG=$( cd "$DELETED" && EXCLUDE_GLOBS="" MAX_REVIEW_BYTES=0 \
  python3 "$SCRIPT" --manifest out_deleted "$DEL_BASE" "$DEL_HEAD" )

check "a deleted binary is sniffed from its pre-image blob" \
  '1' "$(printf '%s\n' "$DEL_LOG" | grep -c '^  ~ gone\.bin$')"
check "so an ordinary deletion raises no attribute conflict" \
  '0' "$(printf '%s\n' "$DEL_LOG" | grep -c '^Attribute conflict ' || true)"
check "and its row says binary rather than sending the reviewer to a gone file" \
  '1' "$(grep -c '^removed	0	gone\.bin	binary$' \
    "$DELETED/out_deleted/manifest.tsv")"

# ----------------------------------------------------------------------------
# Part 1e -- cat-file ends the stream
# ----------------------------------------------------------------------------
#
# THE DEFECT, and it is the gitlink desync one layer down. `readline` on a
# dead `cat-file` returns an EMPTY LINE, which splits into no fields -- and
# the test that catches the two-field `<sha> missing` answer is a field
# COUNT, so it caught the end of the stream too and called it "no body to
# drain". Every sha after that point was written down a closed pipe and left
# with no verdict, `git_records` defaults an absent verdict to "not binary",
# and a genuinely binary file among them then contradicts `git diff` and is
# reported as an ATTRIBUTE CONFLICT -- the pull request accused of an attack
# by an instrument that had stopped reading. Measured before the fix, against
# a stream answering one object of three: `verdicts: {'aaaaaaa': False}`, no
# error, no exit code.
#
# A substitute for `subprocess.Popen` rather than a repository, because a
# half-answered stream is not a state a real `git cat-file` can be asked for.
# The third case is the guard that matters most: the fix must not swallow the
# `missing` answer it sits next to.

CATFILE_OUT=$(cd "$HERE" && python3 - <<'PYEOF'
import io
import sys

sys.path.insert(0, ".")
import filter_diff  # noqa: E402  -- after the path is set


class Stub:
    """A cat-file whose answers and exit code the test chooses."""

    def __init__(self, answers, returncode=0):
        self.answers = answers
        self.code = returncode
        self.returncode = 0
        self.stdin = io.BytesIO()
        self.stdout = io.BytesIO(answers)

    def __call__(self, *args, **kwargs):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.returncode = self.code
        return False


def attempt(answers, returncode=0):
    filter_diff.subprocess.Popen = Stub(answers, returncode)
    try:
        return "verdicts %s" % filter_diff.sniff_binary(["aaaaaaa", "bbbbbbb", "ccccccc"])
    except filter_diff.GitError as exc:
        return "GitError %s" % exc


def blob(body):
    return b"x blob %d\n" % len(body) + body + b"\n"


print("eof:", attempt(blob(b"hello")))
print("exit:", attempt(blob(b"a") + b"bbbbbbb missing\n" + blob(b"c"), returncode=128))
print("healthy:", attempt(blob(b"\x00bin") + b"bbbbbbb missing\n" + blob(b"text")))
PYEOF
)
line_of() { printf '%s\n' "$CATFILE_OUT" | sed -n "s/^$1: //p"; }

check "a stream that ends mid-set is an error, not a silent partial answer" \
  'GitError cat-file ended the stream before answering bbbbbbb' "$(line_of eof)"
check "and a cat-file that exited non-zero does not pass for a clean run" \
  'GitError cat-file exited 128' "$(line_of exit)"
check "while a complete stream still reads its missing answer as before" \
  "verdicts {'aaaaaaa': True, 'ccccccc': False}" "$(line_of healthy)"

# ----------------------------------------------------------------------------
# Part 2 -- unified-diff fallback
# ----------------------------------------------------------------------------

printf '%s\n' \
  'diff --git a/pkg/real.go b/pkg/real.go' \
  '--- a/pkg/real.go' \
  '+++ b/pkg/real.go' \
  '@@ -1 +1 @@' \
  '-old' \
  '+new' \
  'diff --git "a/caf\303\251.png" "b/caf\303\251.png"' \
  'Binary files a/caf\303\251.png and b/caf\303\251.png differ' \
  'diff --git a/old/name.go b/new/name.go' \
  'similarity index 90%' \
  'rename from old/name.go' \
  'rename to new/name.go' \
  'diff --git a/gone.lock b/gone.lock' \
  'deleted file mode 100644' \
  '--- a/gone.lock' \
  '+++ /dev/null' \
  '@@ -1 +0,0 @@' \
  '-x' \
  'diff --git a/vendor/dep/x.go b/vendor/dep/x.go' \
  '--- a/vendor/dep/x.go' \
  '+++ b/vendor/dep/x.go' \
  '@@ -1 +1 @@' \
  '-a' \
  '+b' \
  'diff --git a/oldpkg/mod.go b/newpkg/mod.go' \
  'similarity index 87%' \
  'rename from oldpkg/mod.go' \
  'rename to newpkg/mod.go' \
  '--- a/oldpkg/mod.go' \
  '+++ b/newpkg/mod.go' \
  '@@ -1 +1 @@' \
  '-package oldpkg' \
  '+package newpkg' \
  > "$WORK/in.diff"

result() { # result <globs> -> prints "<count>|<comma-joined dropped paths>"
  local out count paths
  out=$(EXCLUDE_GLOBS="$1" python3 "$SCRIPT" "$WORK/in.diff" "$WORK/out.diff")
  count=$(printf '%s\n' "$out" \
    | sed -n 's/^Excluded \([0-9][0-9]*\) file(s).*/\1/p')
  paths=$(printf '%s\n' "$out" | sed -n 's/^  - //p' | paste -sd, -)
  printf '%s|%s\n' "$count" "$paths"
}

echo "filter_diff.py <in> <out>"
check "quoted non-ASCII binary path is dropped" \
  '1|café.png' "$(result '*.png')"
check "deleted file matches on its pre-image path" \
  '1|gone.lock' "$(result '*.lock')"
check "anchored vendor glob drops the vendored file" \
  '1|vendor/dep/x.go' "$(result 'vendor/*')"
check "pure rename matches on the NEW path (header fallback)" \
  '1|new/name.go' "$(result 'new/*')"
check "pure rename does NOT match on the old path" \
  '0|' "$(result 'old/*')"
check "rename with content changes matches +++ (the NEW path)" \
  '1|newpkg/mod.go' "$(result 'newpkg/*')"
check "rename with content changes ignores --- (the old path)" \
  '0|' "$(result 'oldpkg/*')"
check "a normal source file is kept" \
  '0|' "$(result '*.rs')"
check "anchored glob does not match a lookalike dir" \
  '0|' "$(result 'endor/*')"

python3 "$SCRIPT" "$WORK/in.diff" "$WORK/noop.diff" >/dev/null
if cmp -s "$WORK/in.diff" "$WORK/noop.diff"; then
  echo "  ok    empty EXCLUDE_GLOBS is a byte-identical no-op"
else
  echo "  FAIL  empty EXCLUDE_GLOBS altered the diff" >&2
  FAILED=1
fi

# The no-op above runs the empty-globs path, which the workflow never uses.
# This one exercises the path that actually filters, with a latin-1 byte in the
# kept section: text-mode I/O with errors="replace" silently rewrote it.
printf 'diff --git a/latin.txt b/latin.txt\n--- a/latin.txt\n+++ b/latin.txt\n' \
  > "$WORK/keep.expected"
printf '@@ -1 +1 @@\n-caf\351\n+caf\351s\n' >> "$WORK/keep.expected"
cat "$WORK/keep.expected" > "$WORK/latin.diff"
printf 'diff --git a/logo.png b/logo.png\n' >> "$WORK/latin.diff"
printf 'Binary files a/logo.png and b/logo.png differ\n' >> "$WORK/latin.diff"
EXCLUDE_GLOBS='*.png' python3 "$SCRIPT" \
  "$WORK/latin.diff" "$WORK/latin.out" >/dev/null
if cmp -s "$WORK/keep.expected" "$WORK/latin.out"; then
  echo "  ok    invalid UTF-8 survives the filtering path byte-identically"
else
  echo "  FAIL  invalid UTF-8 was rewritten by the filtering path" >&2
  FAILED=1
fi

if LC_ALL=POSIX EXCLUDE_GLOBS='*.png' python3 "$SCRIPT" \
     "$WORK/in.diff" "$WORK/posix.diff" >/dev/null 2>&1; then
  echo "  ok    survives LC_ALL=POSIX"
else
  echo "  FAIL  crashed under LC_ALL=POSIX" >&2
  FAILED=1
fi

printf 'diff --git a/x.go b/x.go\r\n--- a/x.go\r\n+++ b/x.go\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n' \
  > "$WORK/crlf.diff"
python3 "$SCRIPT" "$WORK/crlf.diff" "$WORK/crlf.out" >/dev/null
if cmp -s "$WORK/crlf.diff" "$WORK/crlf.out"; then
  echo "  ok    CRLF line endings survive unchanged"
else
  echo "  FAIL  CRLF line endings were rewritten" >&2
  FAILED=1
fi


# --help is a request, not a usage error: stdout and exit 0. Printed from the
# header comment by shape, never by line number -- a magic number drifts the
# moment the header grows, silently.
echo "filter_diff.py --help"
if HELP=$(python3 "$SCRIPT" --help 2>/dev/null); then
  check "--help prints usage to stdout and exits 0" \
    'usage: filter_diff.py --manifest <out_dir> <base_rev> <head_rev> [<files_json>]' \
    "$(printf '%s\n' "$HELP" | head -1)"
else
  echo "  FAIL  --help exited non-zero or wrote nothing to stdout" >&2
  FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then
  echo "all passed"
fi
exit "$FAILED"
