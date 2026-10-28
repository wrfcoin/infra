FROM node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53

# Install rtl_433 for SDR packet capture.
# alpine 3.23 renamed rtl-sdr-dev to librtlsdr-dev, and node:*-alpine ships no
# git — both were latent here because the base tag is unpinned and floated.
RUN apk add --no-cache librtlsdr-dev libusb-dev && \
    apk add --no-cache --virtual .build-deps build-base cmake git && \
    git clone --depth 1 https://github.com/merbanan/rtl_433.git /tmp/rtl_433 && \
    cd /tmp/rtl_433 && \
    mkdir build && \
    cd build && \
    cmake -DCMAKE_INSTALL_PREFIX=/usr/local .. && \
    make && \
    make install && \
    cd / && \
    rm -rf /tmp/rtl_433 && \
    apk del .build-deps

WORKDIR /app

# Copy service code
COPY testnet/services/sdr-ingest/src/sdr-ingest.js .
COPY testnet/services/sdr-ingest/fixtures ./fixtures

# Create non-root user for security
RUN addgroup -g 1001 -S appgroup && \
    adduser -S appuser -u 1001 -G appgroup && \
    chown -R appuser:appgroup /app

USER appuser

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD node -e "const http = require('http'); http.get('http://localhost:9000/health', (r) => process.exit(r.statusCode < 300 ? 0 : 1)).on('error', () => process.exit(1))"

EXPOSE 9000

ENTRYPOINT ["node", "sdr-ingest.js"]
