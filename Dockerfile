# ============================================================================
# Autobot - Multi-stage Docker build
# Target: Alpine-based image < 50MB with static binary
# ============================================================================

# Stage 1: Build static binary
FROM crystallang/crystal:latest-alpine AS builder

WORKDIR /src

# Install dependencies first (cached layer)
COPY shard.yml shard.lock* ./
RUN shards install --production

# Copy source and build
COPY src/ src/

RUN crystal build src/main.cr \
    -o /usr/local/bin/autobot \
    --release --no-debug --static \
    && strip /usr/local/bin/autobot

# Stage 2: Minimal runtime image
FROM alpine:3.19

RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    && adduser -D -h /home/autobot autobot

COPY --from=builder /usr/local/bin/autobot /usr/local/bin/autobot

# Create config and workspace directories
RUN mkdir -p /home/autobot/.autobot/workspace \
    && chown -R autobot:autobot /home/autobot/.autobot

USER autobot
WORKDIR /home/autobot

# Volume for persistent config and workspace
VOLUME ["/home/autobot/.autobot"]

ENTRYPOINT ["autobot"]
CMD ["--help"]
