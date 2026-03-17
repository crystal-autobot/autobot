---
name: crystal-dev
description: Crystal development workflow with Ameba linting and spec testing
metadata:
  author: renich
  scope: development
  language: crystal
---

## Crystal Development Standards

### Code Quality Workflow

Always run these checks before committing:

```bash
# 1. Format code
crystal tool format

# 2. Run linter and tests via Makefile
make test

# 3. Build release (if applicable)
make release
```

### Ameba Rules (Zero Tolerance)

- **No formatting warnings** - Code must be formatted with `crystal tool format`
- **No cyclomatic complexity violations** - Keep methods simple (max complexity: 10)
- **No style violations** - Follow Crystal style guide
- **No naming violations** - Use proper naming conventions
- **No not_nil! usage** - Avoid unsafe nil handling

### Testing Standards

- **AAA Pattern**: Arrange, Act, Assert
- Test edge cases and error conditions
- Use descriptive test names
- Keep tests fast and independent
- Run `crystal spec` before any commit

### Common Fixes

**Replace `not_nil!` with safe handling:**
```crystal
# Bad
result.content.not_nil!.should contain("text")

# Good
if content = result.content
  content.should contain("text")
else
  fail("Expected content")
end
```

**Fix block parameter names:**
```crystal
# Bad
.map { |p| Regex.new(p) }

# Good
.map { |pat| Regex.new(pat) }
```

### Project Structure

- `src/autobot/` - Source code
- `spec/` - Test files (mirror src structure)
- `docs/` - Documentation (RST format preferred)
- `bin/ameba` - Linter binary

### Related Files

**Configuration:**
- `shard.yml` - Dependencies and project metadata
- `Makefile` - Build automation
- `.ameba.yml` - Linter configuration

**Style Reference:**
- `src/autobot/providers/http_provider.cr` - Example of well-formatted Crystal code
- `src/autobot/tools/exec.cr` - Complex tool with proper error handling

## When to Use

Use this skill when:
- Writing or modifying Crystal code
- Fixing linter errors
- Creating new specs
- Preparing code for review
- Setting up development environment

**Related Skills:** `autobot-test`, `autobot-provider`, `autobot-tool`
