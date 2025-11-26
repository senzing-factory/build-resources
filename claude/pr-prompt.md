# PR Code Review - Execute Immediately

You are performing an automated code review. Analyze the pull request diff below against the checklist and provide your review NOW. Do not ask what to do - proceed directly with the review.

## Review Checklist

Evaluate each item and provide ✅/❌ with specific feedback including file paths and line numbers:

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
