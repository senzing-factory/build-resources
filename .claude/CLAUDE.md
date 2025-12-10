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

- **`linter.yaml`**: Reusable workflow wrapping super-linter v8.3.0
- **`claude-pull-request-review.yaml`**: Automated Claude Code PR reviews using prompts from `claude/pr-prompt.md`
- **`lint-repo.yaml`**: This repo's own linting configuration

## Claude Code Commands

The `/senzing` slash command (defined in `.claude/commands/senzing.md`) provides two subcommands:

- `changelog-update`: Updates CHANGELOG.md following keepachangelog.com and semver.org standards
- `code-review`: Performs code review against the Senzing checklist

The prompts for these commands are hosted at `claude/senzing-changelog-update.md` and `claude/senzing-code-review.md`.

## Code Review Standards

When reviewing code in Senzing repositories, evaluate against:

- Code style guide at `https://raw.githubusercontent.com/senzing-garage/knowledge-base/refs/heads/main/WHATIS/code-style.md`
- Markdown should follow CommonMark specification and be formatted with prettier
- Flag any `.lic` files or strings starting with `AQAAAD` as critical security issues
- CHANGELOG.md should be updated for all changes

## AWS Scripts

`aws/docker-build.sh` builds and pushes multi-platform Docker images to ECR (and optionally DockerHub). Requires:

- `PLATFORMS` environment variable for target architectures
- `PUSH_TO_DOCKERHUB=true` to also push to DockerHub
