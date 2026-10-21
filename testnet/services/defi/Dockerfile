# rust:1.88-bookworm (multi-arch index digest, resolved 2026-10-05; same digest as infra/docker/Dockerfile.storage)
FROM rust:1.88-bookworm@sha256:af306cfa71d987911a781c37b59d7d67d934f49684058f96cf72079c3626bfe0 AS builder
WORKDIR /src
ARG DEFI_REVISION
COPY .cache/source/ /src/
COPY .cache/registry/ /usr/local/cargo/registry/
COPY healthcheck.rs /probe/healthcheck.rs
RUN test "$(cat .revision)" = "$DEFI_REVISION" \
    && CARGO_BUILD_JOBS=3 cargo build --release --offline --locked -p defi-node \
    && rustc --edition=2021 -D warnings -C opt-level=2 /probe/healthcheck.rs -o /probe/defi-healthcheck

# gcr.io/distroless/cc-debian12:nonroot (multi-arch index digest, resolved 2026-10-05; same digest as infra/docker/Dockerfile.storage)
FROM gcr.io/distroless/cc-debian12:nonroot@sha256:9dac0a79194e45a7da0158a9c6da57b217585af0786db3845d1f0ec1a0dd182f
ARG DEFI_REVISION
LABEL org.opencontainers.image.source="https://github.com/wrfcoin/defi-protocols" \
      org.opencontainers.image.revision="$DEFI_REVISION"
COPY --from=builder /src/target/release/defi-node /usr/local/bin/defi-node
COPY --from=builder /probe/defi-healthcheck /usr/local/bin/defi-healthcheck
COPY --from=builder /src/crates/defi-node/fixtures/pools.toml /etc/defi-node/pools.toml
ENV DEFI_NODE_BIND=0.0.0.0:7100 DEFI_NODE_POOLS=/etc/defi-node/pools.toml
EXPOSE 7100
ENTRYPOINT ["/usr/local/bin/defi-node"]
