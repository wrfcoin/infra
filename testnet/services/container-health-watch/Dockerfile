# WRFCoin testnet container-health watcher (infra#902).
# Local build only — never push to a registry, matching every other testnet
# service image in this repo.
FROM python:3.14-alpine

COPY container_health_watch.py /app/container_health_watch.py

EXPOSE 9201

# 127.0.0.1, not localhost: infra#900/#901 measured this container family's
# `localhost` resolving IPv6 first while a Python http.server bound here
# listens IPv4 0.0.0.0 — a localhost healthcheck would fail while the
# service is perfectly reachable. Same fix, applied before the bug had a
# chance to recur here.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
  CMD wget -q -O /dev/null http://127.0.0.1:9201/health || exit 1

CMD ["python3", "/app/container_health_watch.py"]
