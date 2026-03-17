---
name: autobot-release
description: Create proper releases following EVALinux standards with signed tags and changelogs
tags:
  - release
  - git
  - semver
metadata:
  author: renich
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

### Changelog

Use Keep a Changelog format (Markdown):

```markdown
# Changelog

## [1.2.3] - 2026-03-17

### Added
- New feature description

### Fixed
- Bug fix description

### Changed
- Change description
```

Sections:
- `Added` - New features
- `Changed` - Changes to existing functionality
- `Deprecated` - Soon-to-be removed features
- `Removed` - Removed features
- `Fixed` - Bug fixes
- `Security` - Security improvements

### Git Commands

```bash
# 1. Update changelog
vim CHANGELOG.md

# 2. Update version in shard.yml
vim shard.yml

# 3. Commit version bump
git add CHANGELOG.md shard.yml
git commit -m "chore(release): bump version to 1.2.3"

# 4. Create signed tag (requires GPG key)
git tag -s v1.2.3 -m "Release v1.2.3"

# 5. Push with tags
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
  --notes-file CHANGELOG.md \
  --verify-tag
```

Or manually:
1. Go to GitHub Releases
2. Click "Draft a new release"
3. Choose the signed tag
4. Copy relevant changelog section
5. Publish release

### Co-authored-by

Add to commits when working with AI:
```
Co-authored-by: Assistant <renich+assistant@evalinux.com>
```

Or for specific models:
```
Co-authored-by: Gemini <renich+gemini@woralelandia.com>
```

### Related Files

**Version and Changelog:**
- `shard.yml` - Version field (line 2)
- `CHANGELOG.md` - Release history
- `src/autobot/version.cr` - Auto-generated from shard.yml

**CI/CD:**
- `.github/workflows/ci.yml` - GitHub Actions workflow
- `Makefile` - Build and release targets

**Examples:**
- Look at recent tags: `git log --oneline --tags | head -10`
- View previous releases on GitHub for format examples

## When to Use

Use this skill when:
- Preparing a new release
- Creating version tags
- Writing changelogs
- Bumping version numbers
- Publishing to GitHub

**Related Skills:** `crystal-dev`
