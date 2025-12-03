# PR Code Review - Execute Immediately

You are performing an automated code review. Analyze against the following checklist

- If this is running on a local developers machine with the command `/senzing-code-review`:
  - The review should be against local changes in the Git diff.
- If this is running on GitHub:
  - Read any existing comments on the pull request and consider them in your review.
  - Analyze the pull request diff below and provide your review NOW. Do not ask what to do - proceed directly with the review.

## Review Checklist

Evaluate each item and provide ✅/❌ with specific feedback including file paths and line numbers (line numbers should be specific to the complete file, not from the diff):

### Code Quality

- [ ] Code follows our style guide: `https://raw.githubusercontent.com/senzing-garage/knowledge-base/refs/heads/main/WHATIS/code-style.md`
- [ ] No commented-out code
- [ ] Meaningful variable names
- [ ] DRY principle followed
- [ ] Identify Defects: Look for bugs, logic errors, edge cases, potential crashes, race conditions, memory leaks, and security vulnerabilities
- [ ] If there is a project memory claude configuration (./.claude/CLAUDE.md), consider it in the review. The project memory claude configuration should not contain anything that would be specific to a local development environment. It should be general enough that it can be used for any local developer.

### Testing

- [ ] Unit tests for new functions
- [ ] Integration tests for new endpoints
- [ ] Edge cases covered
- [ ] Test coverage > 80%

### Documentation

- [ ] Readme updated if needed
- [ ] API docs updated
- [ ] Inline comments for complex logic
- [ ] CHANGELOG.md updated
- [ ] Markdown files should follow the CommonMark specification: `https://commonmark.org/`. There should be no extra whitespaces and they should be formatted with prettier.

### Security

- [ ] No hardcoded credentials
- [ ] Input validation implemented
- [ ] Proper error handling
- [ ] No sensitive data in logs
- [ ] Flag any checked in license files (.lic) as critical. Include files containing strings starting with `AQAAAD`

---

## Pull Request Diff to Review

[diff will be appended here]

---

**BEGIN YOUR REVIEW NOW** - Provide your analysis of the above diff against each checklist item.
