name: crystal-dev
description: Crystal development workflow with Ameba linting and spec testing
metadata:
  scope: development
  language: crystal
---

## Crystal Development Standards

### Ameba Rules (Zero Tolerance)

All code must pass `ameba` checks. Key rules enforced:
- **No formatting warnings** - Code must be formatted with `crystal tool format`
- **No cyclomatic complexity violations** - Keep methods simple (max complexity: 10)
- **No style violations** - Follow Crystal style guide
- **No naming violations** - Use proper naming conventions
- **No not_nil! usage** - Avoid unsafe nil handling

### Common Fixes

**Replace `not_nil!` with safe handling:**
```crystal
# Bad
result.content.not_nil!.should contain("text")

# Good
if content = result.content
  content.should contain("text")
else
  fail("Expected content to not be nil")
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
- `spec/` - Test files (mirror `src/` structure)
- `docs/` - Documentation (Markdown for README/docs)
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
