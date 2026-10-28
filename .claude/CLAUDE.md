# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is a **shared build resources repository** for the Senzing organization. It provides:

- Reusable GitHub Actions workflow templates (`.github/workflows/`)
- Claude Code prompts for PR reviews and changelog updates (`claude/`)
- AWS ECR deployment scripts (`aws/`)
- Linter configurations (`.github/linters/`)

This repository is consumed by other Senzing repositories via GitHub Actions workflow references (e.g., `uses: senzing-factory/build-resources/.github/workflows/linter.yaml@v3`).

## Linting

The repository uses [super-linter](https://github.com/super-linter/super-linter) for all linting via the reusable workflow at `.github/workflows/linter.yaml`. Linting runs automatically on push to non-main branches and on PRs to main.

To lint locally, use the super-linter Docker container:

```bash
docker run --rm \
  -e DEFAULT_BRANCH=main \
  -e VALIDATE_ALL_CODEBASE=true \
  -v "$(pwd)":/tmp/lint \
  ghcr.io/super-linter/super-linter:latest
```

## Key Workflows

- **`linter.yaml`**: Reusable workflow wrapping super-linter v8.7.0
- **`claude-pull-request-review.yaml`**: Automated Claude Code PR reviews using the prompt at `claude/pr-prompt-v2.md` and eight helper programs in `claude/`, seven of them with a fixture suite run by `lint-repo.yaml` (`review_io.py` has none):
  - `filter_diff.py` assembles the review set. Every fact in the manifest comes from git plumbing over the merge base to the PR head; `pulls/{n}/files` is used only as a second witness to the file list, and a disagreement aborts the run. Binary-ness is read from the blob with `git cat-file`, never from `.gitattributes`, which the PR under review owns
  - `pr_discussion.py` renders the PR's description and comment thread as untrusted context: a run-random fence, a `|` prefix, pipe then space, on every author line, covert channels removed and the removals declared
  - `review_coverage.py` measures which manifest rows the reviewer actually opened, from the run's own `stream-json` transcript rather than from anything the model says about itself
  - `review_output.py` turns the model's schema-validated findings into the comment body, rejecting filler -- padding whose citation does not resolve at the base ref, blindness dressed as a finding, a finding whose own text says there is nothing to flag, an anchor that does not resolve -- and counting each rejection. Duplicate findings are DROPPED, never merged -- same path, same line, same message once case and punctuation are set aside, highest severity surviving; `collapse()` records what merging cost and why it is gone. `--restored` names the paths the workflow reverted to the merge base, whose line numbers cannot be checked against the checkout and so are disclosed rather than downgraded
  - `review_text.py` recovers the review from that transcript: the `structured_output` of the last `result` event, which the CLI has already validated against `claude/review-schema.json`. There is no text fallback -- under the schema the findings exist only as the tool call's argument
  - `review-git` is the reviewer's only route to git history: `log`, `show` and `diff`, with the options that write a file or run a program named by the repository's own config refused and every path argument held inside the checkout. A wrapper rather than a `Bash(git log:*)` prefix, which bounds the start of the command string and nothing after it
  - `review-note` is where the reviewer puts what it checked and found clean, so that text reaches the job log and never the comment
  - `review_io.py` holds the file conventions the others share
- The review posts **one comment, edited in place**: the comment is found by the token's runtime-resolved identity (GraphQL `viewer.databaseId`, since `GET /user` 403s for an installation token) plus the marker in the body, and updated with `PATCH` so GitHub keeps its revision history
- **`lint-repo.yaml`**: This repo's own linting configuration

## Claude Code Commands

The `/senzing` slash command (defined in `.claude/commands/senzing.md`) provides two subcommands:

- `changelog-update`: Updates CHANGELOG.md following keepachangelog.com and semver.org standards
- `code-review`: Performs code review against the Senzing checklist

The prompts for these commands live in `senzing-factory/claude` at tag `v1`, which is what `.claude/commands/senzing.md` fetches. They are NOT in this repository's `claude/` directory -- that holds the automated PR-review prompts (`claude/pr-prompt.md`, still read by the released `v4` workflow, and `claude/pr-prompt-v2.md`, read by the current one) and their helper, which are a different thing.

## Code Review Standards

When reviewing code in Senzing repositories, evaluate against:

- Code style guide at `https://raw.githubusercontent.com/senzing-garage/knowledge-base/refs/heads/main/WHATIS/code-style.md`
- Markdown should follow CommonMark specification and be formatted with prettier
- Flag any `.lic` files or strings starting with `AQAAAD` as critical security issues
- CHANGELOG.md: demand one only where the repository's own history shows that
  comparable changes updated it. Measured 2026-10-06 across 4,932 fleet reviews,
  the blanket rule produced a CHANGELOG complaint in 62.3% of reviews and a
  BLOCKING demand in 38.4% -- including in 17 repositories that have no
  CHANGELOG file at all, where 36.8% of reviews carried a false blocker. This
  repository's own CHANGELOG.md is still the unedited template, so the rule
  contradicted itself here too. `claude/pr-prompt-v2.md` encodes the
  history-based test; this line used to contradict it.

## AWS Scripts

`aws/docker-build.sh` builds and pushes multi-platform Docker images to ECR (and optionally DockerHub). Requires:

- `PLATFORMS` environment variable for target architectures
- `PUSH_TO_DOCKERHUB=true` to also push to DockerHub
