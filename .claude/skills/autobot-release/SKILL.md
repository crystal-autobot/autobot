---
name: autobot-release
description: Create proper releases following EVALinux standards with signed tags and changelogs
tags:
  - release
  - git
  - semver
metadata:
  scope: maintenance
---

## Release Workflow

### Prerequisites

Ensure all checks pass before releasing:
```bash
crystal spec      # All tests must pass
./bin/ameba       # No warnings or failures
make release      # Build must succeed
```

### Version Bump

Follow Semantic Versioning (SemVer):
- **MAJOR** - Breaking changes (incompatible API changes)
- **MINOR** - New features (backward compatible)
- **PATCH** - Bug fixes (backward compatible)

Update version in:
- `shard.yml` (Crystal standard)
- Git tag

### Git Commands

```bash
# 1. Update version in shard.yml

# 2. Commit version bump
git add shard.yml
git commit -m "chore(release): bump version to 1.2.3"

# 3. Create signed tag (requires GPG key)
git tag -s v1.2.3 -m "Release v1.2.3"

# 4. Push with tags
git push origin main --follow-tags
```

### Conventional Commits

Use throughout development:
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation only
- `style:` - Formatting, missing semicolons, etc.
- `refactor:` - Code change that neither fixes bug nor adds feature
- `perf:` - Performance improvement
- `test:` - Adding tests
- `chore:` - Build process or auxiliary tool changes

Format:
```
type(scope): description

[optional body]

[optional footer]
```

### GitHub Release

Create release via GitHub CLI:
```bash
gh release create v1.2.3 \
  --title "Release v1.2.3" \
  --verify-tag
```

Or manually:
1. Go to GitHub Releases
2. Click "Draft a new release"
3. Choose the signed tag
4. Add release notes
5. Publish release

## When to Use

Use this skill when:
- Preparing a new release
- Creating version tags
- Bumping version numbers
- Publishing to GitHub

**Related Skills:** `autobot-test`
