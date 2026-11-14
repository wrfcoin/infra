# Wrfcoin ML Inference Service — multi-stage build
# Stage 1: install build dependencies and compile wheels
FROM python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Build context is the deploy root (the parent of this repo), so that
# backend/services/ml/ below resolves — see docker-compose.yml ml-inference.
COPY infra/infra/tools/requirements-ml.txt ./requirements-ml.txt
RUN pip install --no-cache-dir --prefix=/install -r requirements-ml.txt

# Stage 2: runtime image — no build tools
FROM python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user with dedicated group (not root)
RUN groupadd -r wrfcoin && useradd -r -u 1001 -g wrfcoin wrfcoin

# Copy installed Python packages from builder
COPY --from=builder /install /usr/local

# Copy ML service code with proper ownership
COPY --chown=wrfcoin:wrfcoin backend/services/ml/ ./src/ml/

# `backend/models/` does not exist in any repository in this workspace, so the
# COPY that used to be here could never resolve. The service keeps an in-memory
# registry and loads models at runtime via POST /models/load, so an empty,
# writable mount point is what it actually needs.
RUN mkdir -p ./models && chown wrfcoin:wrfcoin ./models

USER wrfcoin

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

CMD ["python", "-m", "src.ml.inference_server"]
