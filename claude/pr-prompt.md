# PR Code Review Prompt

Review this PR against our team checklist (Provide specific feedback, reference exact file paths and line numbers when possible):

## Code Quality

- [ ] Code follows our style guide: https://github.com/senzing-garage/knowledge-base/blob/main/WHATIS/code-style.md
- [ ] No commented-out code
- [ ] Meaningful variable names
- [ ] DRY principle followed
- [ ] Identify Defects: Look for bugs, logic errors, edge cases, potential crashes, race conditions, memory leaks, and security vulnerabilities

## Testing

- [ ] Unit tests for new functions
- [ ] Integration tests for new endpoints
- [ ] Edge cases covered
- [ ] Test coverage > 80%

## Documentation

- [ ] README updated if needed
- [ ] API docs updated
- [ ] Inline comments for complex logic
- [ ] CHANGELOG.md updated

## Security

- [ ] No hardcoded credentials
- [ ] Input validation implemented
- [ ] Proper error handling
- [ ] No sensitive data in logs
- [ ] Flag any checked in license files (.lic) as critical. Include files containing strings starting with `AQAAAD`

For each item, provide ✅/❌ and explain any issues.
