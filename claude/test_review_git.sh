#!/usr/bin/env bash
# cspell:ignore textconv fsmonitor rgit  -- git option names / a local function
# Fixture tests for review-git, the wrapper that replaced five
# `Bash(git <subcommand>:*)` grants on the pull request reviewer.
#
# WHY THIS SUITE EXISTS. `Bash(cmd:*)` bounds the START of a command string
# and nothing after it, so the grants it replaced meant "git log with ANY
# arguments" -- an arbitrary file write by `--output`, and from there remote
# code execution by way of a `[diff "x"] command` stanza written into
# `.git/config` and fired with `git log -p --ext-diff`. The wrapper is the
# only thing standing between the reviewer and that chain, so every refusal
# it makes is asserted here.
#
# The last part builds a throwaway repository, poisons its `.git/config` with
# both an external-diff and a textconv driver, and asserts that neither fires
# through the wrapper -- which is a stronger claim than "the flag is
# rejected": a textconv driver runs on a plain `git diff` with no flag at all.
#
# Usage:  ./test_review_git.sh      # from anywhere; exits non-zero on failure
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/review-git"
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

# The repository under test. Two commits, so HEAD^ resolves and a diff has
# something in it, and `commit.gpgsign` forced off so a signing config on the
# machine running this cannot stop it.
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email tests@example.com
git -C "$REPO" config user.name tests
git -C "$REPO" config commit.gpgsign false
printf 'hello\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm "first"
printf 'world\n' >> "$REPO/a.txt"
# A tracked file whose NAME contains `=`, and a subdirectory, both for the
# `--name=value` split: the split must not reach a pathspec, and `--relative`
# must keep working with a value that stays inside the tree.
printf 'equals\n' > "$REPO/a=b.txt"
mkdir -p "$REPO/sub"
printf 'nested\n' > "$REPO/sub/c.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "second"

rgit() { # rgit <args...> -> exit status; stdout to $WORK/out, stderr to $WORK/err
  local status=0
  ( cd "$REPO" && "$SCRIPT" "$@" ) > "$WORK/out" 2> "$WORK/err" || status=$?
  return "$status"
}

refused() { # refused <label> <args...>
  local label="$1"
  shift
  if rgit "$@"; then
    echo "  FAIL  $label: exited 0" >&2
    FAILED=1
    return
  fi
  if ! grep -q '^review-git: refusing' "$WORK/err"; then
    echo "  FAIL  $label: no refusal on stderr, got '$(head -1 "$WORK/err")'" >&2
    FAILED=1
    return
  fi
  if [ -s "$WORK/out" ]; then
    echo "  FAIL  $label: wrote to stdout as well as refusing" >&2
    FAILED=1
    return
  fi
  echo "  ok    $label"
}

allowed() { # allowed <label> <args...>
  local label="$1"
  local status=0
  shift
  rgit "$@" || status=$?
  if [ "$status" -eq 0 ] && [ -s "$WORK/out" ]; then
    echo "  ok    $label"
  else
    echo "  FAIL  $label: status ${status} / stderr '$(head -1 "$WORK/err")'" >&2
    FAILED=1
  fi
}

echo "review-git: allowed subcommands"
allowed "log runs" log -1 --oneline
allowed "show runs" show -s --format=%s -1
allowed "diff runs" diff --name-only HEAD^ HEAD
# The path separator must survive the argument scan: the prompt tells the
# reviewer to run `review-git log -20 --oneline -- <file>`, and a scan that
# treated a bare `--` as an option prefix would refuse every one of them.
allowed "a bare -- is a path separator, not an option" log -1 --oneline -- a.txt

echo "review-git: refused arguments"
refused "--output=<path> is refused" log "--output=$WORK/written" --format=%B -1
refused "a bare --output is refused" log --output "$WORK/written" -1
refused "--ext-diff is refused" log -p --ext-diff -1
refused "--textconv is refused" diff --textconv HEAD^ HEAD
refused "--no-index is refused" diff --no-index /etc/hostname /etc/hosts
refused "--exec-path is refused" log --exec-path=/tmp -1
refused "--upload-pack is refused" log --upload-pack=/tmp/x -1
refused "--receive-pack is refused" log --receive-pack=/tmp/x -1
refused "a bare -c is refused" log -c -1
# git expands an unambiguous long-option abbreviation, so the full spelling is
# not the only form that reaches the option.
refused "an abbreviation of --output is refused" log --outp=/tmp/x -1
refused "an abbreviation of --no-index is refused" diff --no-ind /etc/hostname /etc/hosts

# THE IMPLICIT FORM, which is the one that mattered. git implies --no-index
# whenever a path argument lies outside the work tree, so refusing the flag
# refused nothing: each of these printed the file, and the two explicit tests
# above passing is exactly what hid it. The output reaches the model's context
# in a job holding `pull-requests: write`, so it can land in a public comment.
printf 'secret-outside\n' > "$WORK/outside.txt"
mkdir -p "$WORK/elsewhere" "$REPO/empty"
printf 'also-secret\n' > "$WORK/elsewhere/b.txt"

# The control first: plain git in this same repository does print it, so the
# refusals below remove something that works rather than asserting into a void.
( cd "$REPO" && git diff /etc/hostname /dev/null > "$WORK/control" 2>/dev/null ) || true
check "the control leaks an outside file under plain git" '1' \
  "$([ -s "$WORK/control" ] && echo 1 || echo 0)"

refused "an absolute path outside the tree is refused" diff "$WORK/outside.txt" /dev/null
refused "a system file is refused with no flag at all" diff /etc/hostname /dev/null
refused "a relative escape is refused" diff ../outside.txt /dev/null
refused "one path inside and one outside is refused" diff a.txt /etc/hostname
refused "a directory pair that would dump a tree is refused" diff empty "$WORK/elsewhere"
refused "a .. segment inside a longer path is refused" log -1 -- a/../../outside.txt
refused "a bare .. is refused" diff .. /dev/null

# THE VALUE OF A `--name=value`, which the scan above does not reach. Both
# of these are a path argument wearing an option's clothes: the `..` follows
# `=` rather than `/`, so the segment test never saw it, and the absolute
# path begins at `=` rather than at the first character, so the `/*` test
# never saw it either. `--relative` is the live one -- git resolves it
# against the work tree and will walk out of it.
refused "a .. segment in a --name=value is refused" diff --relative=../x HEAD^ HEAD
refused "an absolute path in a --name=value is refused" diff --relative=/etc HEAD^ HEAD
# `-O` names a diff orderfile, which git READS, and a short option with its
# value attached is invisible to every other test here: it starts with `-`,
# so the absolute-path test skips it, and it carries no `--`, so the
# long-option scan skips it too.
refused "-O with an attached value is refused" diff -O/etc/passwd HEAD^ HEAD
# The separated spelling needs no rule of its own -- the value is its own
# argument and the absolute-path test already has it. Asserted so that a
# later narrowing of that test cannot open this without a failure.
refused "-O with a separated value outside the tree is refused" \
  diff -O /etc/passwd HEAD^ HEAD

# The controls for that split, so it cannot be over-refusing in silence. A
# PATHSPEC may legitimately contain `=`, and a `--name=value` whose value
# stays inside the tree is the ordinary use of the option that prompted the
# refusals above.
allowed "a pathspec containing = is still accepted" log -1 --oneline -- a=b.txt
allowed "a --name=value inside the tree is still accepted" \
  diff --relative=sub HEAD^ HEAD
allowed "a --name=value that is not a path at all is still accepted" \
  log -1 --format=%s

# The test is a `..` PATH SEGMENT, not the two characters, or every revision
# range the reviewer is told to use would be refused along with it.
allowed "a two-dot revision range still runs" log --oneline HEAD^..HEAD
allowed "a three-dot revision range still runs" diff --name-only HEAD^...HEAD

# Every invocation the prompt prescribes, under the same rule.
allowed "the prompt's lockfile check still runs" diff --name-only HEAD^ HEAD
allowed "the prompt's convention check still runs" log -20 --oneline -- a.txt
allowed "show HEAD --stat still runs" show HEAD --stat
allowed "a pathspec-limited diff still runs" diff HEAD^ HEAD -- a.txt

check "no refused argument wrote its target file" '0' \
  "$([ -e "$WORK/written" ] && echo 1 || echo 0)"

echo "review-git: subcommand allowlist"
refused "status is refused" status
refused "rev-parse is refused" rev-parse HEAD
refused "a subcommand outside the allowlist is refused" cat-file -p HEAD
# A global option cannot precede the subcommand, which is what keeps
# `git -c diff.external=<program> log` out -- the argument scan never sees it.
refused "-c before the subcommand is refused" -c diff.external=/bin/echo log -p -1
refused "--exec-path before the subcommand is refused" --exec-path=/tmp log -1
refused "--no-pager before the subcommand is refused" --no-pager log -1
if rgit; then
  echo "  FAIL  no arguments at all exits 0" >&2
  FAILED=1
else
  check "no arguments at all is refused" '1' \
    "$(grep -c '^review-git: no subcommand given' "$WORK/err")"
fi

# --help is a request, not a usage error: the header comment on stdout, exit 0.
echo "review-git --help"
if HELP=$("$SCRIPT" --help 2>/dev/null); then
  check "--help prints the header to stdout and exits 0" \
    'review-git -- run one of git'"'"'s three read-only history subcommands with the' \
    "$(printf '%s\n' "$HELP" | head -1)"
  check "--help does not print the shebang or any comment marker" '0' \
    "$(printf '%s\n' "$HELP" | grep -c '^#' || true)"
else
  echo "  FAIL  --help exited non-zero or wrote nothing to stdout" >&2
  FAILED=1
fi

# ---------------------------------------------------------------------------
# The chain itself, not just the flag.
#
# `.git/config` and `.git/info/attributes` are both writable by the primitive
# the wrapper removes, so the wrapper has to hold even once they are poisoned.
# Each driver appends to a marker file, which is how execution is detected
# whether or not its output reaches the diff -- a textconv driver that prints
# the same text for both sides produces an EMPTY diff and no visible trace.
# ---------------------------------------------------------------------------
echo "review-git: a poisoned .git/config does not fire"
MARKER="$WORK/driver-ran"
printf '#!/bin/sh\nprintf ran >> %s\n' "$MARKER" > "$WORK/driver.sh"
chmod +x "$WORK/driver.sh"
{
  printf '[diff "poisoned"]\n'
  printf '\tcommand = %s\n' "$WORK/driver.sh"
  printf '\ttextconv = %s\n' "$WORK/driver.sh"
  printf '[core]\n'
  printf '\tfsmonitor = %s\n' "$WORK/driver.sh"
} >> "$REPO/.git/config"
printf '* diff=poisoned\n' > "$REPO/.git/info/attributes"

# The control: plain git, the same poisoned repository. If this does not fire,
# the assertions below prove nothing and the fixture has silently stopped
# testing anything -- which is the failure mode a security fixture has to
# rule out first.
: > "$MARKER"
( cd "$REPO" && git diff HEAD^ HEAD ) > /dev/null 2>&1 || true
check "the control fires the driver under plain git" '1' \
  "$([ -s "$MARKER" ] && echo 1 || echo 0)"

for case_args in "log -p -1" "diff HEAD^ HEAD" "show -1" "log --stat -1"; do
  : > "$MARKER"
  # shellcheck disable=SC2086  # the fixture's own argument list, split on purpose
  rgit $case_args > /dev/null 2>&1 || true
  check "review-git ${case_args} does not run the poisoned driver" '0' \
    "$([ -s "$MARKER" ] && echo 1 || echo 0)"
done

if [ "$FAILED" -eq 0 ]; then
  echo "all review-git tests passed"
else
  echo "review-git tests FAILED" >&2
fi
exit "$FAILED"
