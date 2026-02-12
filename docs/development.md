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

## Release Artifacts

```bash
make release-all
make checksums
```
