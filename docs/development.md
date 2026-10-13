# Development

## Prerequisites

- Crystal 1.10+
- Shards
- Make

## Build

```bash
make deps
make build      # debug binary
make release    # optimized binary
make static     # static binary (Linux/musl)
```

## Test

```bash
make test
make test-verbose
crystal spec spec/autobot/tools/filesystem_spec.cr
```

## Quality

```bash
make format
make format-check
make lint
```

## Docker

```bash
make docker-build
make docker-run
make docker-shell
make docker-size
```

## Documentation

Preview the docs site locally:

```bash
pip install 'mkdocs<2' mkdocs-material
mkdocs serve
```

This starts a dev server at `http://127.0.0.1:8000/autobot/` with live reload — any changes to `docs/` or `mkdocs.yml` are reflected immediately.

## Releasing

1. Bump `version` in `shard.yml` and merge that change into `main`.
2. Tag the merged commit with the same version (`git tag v0.9.1 && git push origin v0.9.1`).

The release workflow refuses to build when the tag does not match `shard.yml`. `Autobot::VERSION` is compiled from `shard.yml`, so a stale manifest ships binaries that report the previous version.

### Release Artifacts

```bash
make release-all
make checksums
```
