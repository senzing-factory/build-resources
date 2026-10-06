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
- **`claude-pull-request-review.yaml`**: Automated Claude Code PR reviews using the prompt at `claude/pr-prompt-v2.md` and the helper at `claude/filter_diff.py`
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
