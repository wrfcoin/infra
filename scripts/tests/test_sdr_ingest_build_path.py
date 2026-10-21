"""infra#982: sdr-ingest's build input and fixtures bind must resolve to real paths.

Compose resolves `context` against the compose file's directory and
`dockerfile` against the context. The Dockerfile COPYs `testnet/services/...`,
so the context must be the repo root (as faucet does with `..`).
"""
import os
import yaml

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
COMPOSE = os.path.join(ROOT, "testnet", "docker-compose.testnet.yml")


def _service():
    with open(COMPOSE) as f:
        return yaml.safe_load(f)["services"]["sdr-ingest"]


def test_sdr_ingest_dockerfile_resolves():
    b = _service()["build"]
    ctx = os.path.normpath(os.path.join(os.path.dirname(COMPOSE), b["context"]))
    assert os.path.isdir(ctx), ctx
    df = os.path.normpath(os.path.join(ctx, b["dockerfile"]))
    assert os.path.isfile(df), f"sdr-ingest Dockerfile does not exist: {df}"


def test_sdr_ingest_copy_sources_exist_in_context():
    b = _service()["build"]
    ctx = os.path.normpath(os.path.join(os.path.dirname(COMPOSE), b["context"]))
    with open(os.path.normpath(os.path.join(ctx, b["dockerfile"]))) as f:
        srcs = [l.split()[1] for l in f if l.startswith("COPY ") and "--from" not in l]
    assert srcs
    for s in srcs:
        assert os.path.exists(os.path.join(ctx, s)), f"COPY source missing in context: {s}"


def test_sdr_ingest_fixtures_bind_exists():
    binds = [v.split(":")[0] for v in _service()["volumes"] if isinstance(v, str) and v.startswith(".")]
    assert binds
    for b in binds:
        assert os.path.isdir(os.path.normpath(os.path.join(os.path.dirname(COMPOSE), b))), b
