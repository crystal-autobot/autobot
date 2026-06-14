# Autobot

## Rules

1. When making changes, ensure the docs/ also reflect it.
2. **Coding Agents & Assistants (Jules, Claude, Gemini, ChatGPT, Cursor)**:
   - **Scope Boundary**: Modify *only* files directly related to your task. Do not perform global formatting or style cleanups that alter unrelated files (e.g. stripping trailing commas).
   - **Upstream Alignment**: Always branch off the latest commit of the upstream main branch (`crystal-autobot/autobot:main`). Sync fork branches before starting.

## Code Quality Standards

**IMPORTANT:** Always follow Ameba linter rules. All code must pass ameba checks without warnings or failures before committing.

### Ameba Rules
- **No formatting warnings** - Code must be formatted with `crystal tool format`
- **No cyclomatic complexity violations** - Keep methods simple (max complexity: 10), follow it at the beginning to avoid refactoring
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
