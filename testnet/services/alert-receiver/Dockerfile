# WRFCoin testnet AlertManager webhook receiver + notification forwarder (infra#601).
# Baked into a local image (NOT bind-mounted): CT 101 is unprivileged LXC and
# ZFS bind mounts are not supported. Local build only — never push to a registry.
FROM python:3.14-alpine

COPY alertmanager-webhook-receiver.py /app/alertmanager-webhook-receiver.py

USER nobody

EXPOSE 19093

# 127.0.0.1, not localhost: the server binds IPv4 0.0.0.0 and alpine resolves
# localhost to ::1 first, so a localhost healthcheck fails while the service
# is perfectly reachable (observed live on first deploy).
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:19093/health || exit 1

# Stdout is the durable capture (docker json-file logging); forwarding is
# configured via ALERT_FORWARD_URL / ALERT_FORWARD_FORMAT at runtime.
CMD ["python3", "/app/alertmanager-webhook-receiver.py"]
