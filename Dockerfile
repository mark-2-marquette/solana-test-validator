# Two-stage build:
# 1. Build Agave binaries from source (cached — only rebuilds on version bump)
# 2. Layer our fixturenet entrypoint on top

# ---------- Stage 1: Build Agave ----------
FROM rust:1.85-bookworm AS builder

ARG AGAVE_VERSION=v3.1.9

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libssl-dev \
    libudev-dev \
    libclang-dev \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /agave
RUN git clone --depth 1 --branch ${AGAVE_VERSION} https://github.com/anza-xyz/agave.git . \
    && ./scripts/cargo-install-all.sh /solana-release

# ---------- Stage 2: Runtime + entrypoint ----------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libssl3 \
    libudev1 \
    socat \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /solana-release/bin/ /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME /ledger
EXPOSE 8899 8900

ENTRYPOINT ["entrypoint.sh"]
