# Autobot

## Code Quality Standards

**IMPORTANT:** Always follow Ameba linter rules. All code must pass ameba checks without warnings or failures before committing.

### Ameba Rules
- **No formatting warnings** - Code must be formatted with `crystal tool format`
- **No cyclomatic complexity violations** - Keep methods simple (max complexity: 10)
- **No style violations** - Follow Crystal style guide
- **No naming violations** - Use proper naming conventions

If you encounter a complexity warning, refactor by extracting methods rather than ignoring the rule.

## Verification Checks

Run these checks before committing:

```sh
crystal spec      # All tests must pass
./bin/ameba       # No warnings or failures
make release      # Build must succeed
```
