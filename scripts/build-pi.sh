#!/bin/bash
# Build a static ARM64 Linux binary for Raspberry Pi (via Docker on macOS)
#
# Usage:
#   ./scripts/build-pi.sh          # Build and output to build/autobot-linux-arm64
#   ./scripts/build-pi.sh deploy   # Build and scp to Pi
#
# Prerequisites:
#   - Docker Desktop with "Use Rosetta for x86_64/amd64 emulation" disabled
#   - QEMU binfmt support (Docker Desktop includes this)
#
# To deploy, set PI_HOST:
#   PI_HOST=pi@raspberrypi ./scripts/build-pi.sh deploy

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(grep '^version:' shard.yml | cut -d' ' -f2)
OUTPUT="build/autobot-linux-arm64"
PI_HOST="${PI_HOST:-pi@raspberrypi}"
PI_PATH="${PI_PATH:-/usr/local/bin/autobot}"

echo "Building autobot v${VERSION} for linux/arm64 (Raspberry Pi)..."
echo ""

# Ensure Docker is running
if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker is not running. Start Docker Desktop first."
  exit 1
fi

mkdir -p build

docker run --rm --platform linux/arm64 \
  -v "$PWD":/src -w /src \
  crystallang/crystal:latest-alpine \
  sh -c "shards install && crystal build src/main.cr -o ${OUTPUT} --release --no-debug --static --progress"

# Show result
SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
echo ""
echo "Built: ${OUTPUT} (${SIZE})"
file "$OUTPUT"
echo ""

# Deploy if requested
if [ "${1:-}" = "deploy" ]; then
  echo "Deploying to ${PI_HOST}:${PI_PATH}..."
  scp "$OUTPUT" "${PI_HOST}:/tmp/autobot"
  ssh "$PI_HOST" "sudo mv /tmp/autobot ${PI_PATH} && sudo chmod 755 ${PI_PATH}"
  echo "Deployed. Run on Pi: autobot --help"
fi
