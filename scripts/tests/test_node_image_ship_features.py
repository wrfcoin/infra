"""Controls for scripts/check_node_image_ship_features.py (infra#1034).

Hermetic: no core4 checkout, no docker. The real infra files must pass; a Dockerfile.core
carrying `panic-drill` must fail whether the name is written on the `--features` line
(the case core4's `--profile-file` already catches) or reaches it through an ARG default
(the case it does not). The core4-checker side of the same controls runs in
.github/workflows/node-image-ship-guard.yml, which has the core4 checkout.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = ROOT / "infra/docker/Dockerfile.core"
# Every file that builds or passes build args to Dockerfile.core; the workflow scans the same set.
BUILD_FILES = (
    DOCKERFILE,
    ROOT / "testnet/docker-compose.override.yml",
    ROOT / "testnet/docker-compose.oracle-attester.yml",
    ROOT / "infra/docker/docker-compose.yml",
)
NODE_FEATURES_LINE = '      --features "full-mining,p2p,hsm,upgrade-notice-fetch"'

_spec = importlib.util.spec_from_file_location(
    "check_node_image_ship_features", ROOT / "scripts/check_node_image_ship_features.py"
)
guard = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = guard
_spec.loader.exec_module(guard)


def _mutate(tmp_path: Path, name: str, old: str, new: str) -> Path:
    text = DOCKERFILE.read_text(encoding="utf-8")
    assert text.count(old) == 1, f"fixture anchor {old!r} drifted in Dockerfile.core"
    out = tmp_path / name
    out.write_text(text.replace(old, new), encoding="utf-8")
    return out


def test_real_build_files_pass(capsys):
    assert guard.main([str(p) for p in BUILD_FILES]) == 0
    assert "4 file(s) name none of dev-endpoints, panic-drill" in capsys.readouterr().out


def test_node_features_anchor_is_live():
    # The mutations below are only meaningful while this is the node build's feature list.
    text = DOCKERFILE.read_text(encoding="utf-8")
    assert re.search(r"--bin launch_api \\\n" + re.escape(NODE_FEATURES_LINE) + r"\n", text)


def test_literal_panic_drill_fails(tmp_path, capsys):
    bad = _mutate(tmp_path, "lit.Dockerfile", NODE_FEATURES_LINE,
                  '      --features "full-mining,p2p,hsm,upgrade-notice-fetch,panic-drill"')
    assert guard.main([str(bad)]) == 1
    assert "`panic-drill`" in capsys.readouterr().err


def test_arg_indirection_panic_drill_fails(tmp_path, capsys):
    # core4 check_release_endpoints.py --profile-file exits 0 on exactly this file.
    bad = _mutate(
        tmp_path,
        "arg.Dockerfile",
        "FROM builder-base AS node-builder\n",
        'FROM builder-base AS node-builder\nARG FEATURES="full-mining,p2p,hsm,upgrade-notice-fetch,panic-drill"\n',
    )
    bad.write_text(bad.read_text(encoding="utf-8").replace(NODE_FEATURES_LINE, '      --features "${FEATURES}"'),
                   encoding="utf-8")
    assert guard.main([str(bad)]) == 1
    err = capsys.readouterr().err
    assert 'ARG FEATURES="full-mining,p2p,hsm,upgrade-notice-fetch,panic-drill"' in err


def test_env_dev_endpoints_fails(tmp_path):
    bad = _mutate(tmp_path, "env.Dockerfile", "FROM builder-base AS node-builder\n",
                  "FROM builder-base AS node-builder\nENV EXTRA=dev-endpoints\n")
    assert guard.main([str(bad)]) == 1


def test_compose_build_arg_fails(tmp_path):
    compose = tmp_path / "docker-compose.yml"
    compose.write_text(
        "services:\n  node:\n    build:\n      args:\n        FEATURES: full-mining,p2p,panic-drill\n",
        encoding="utf-8",
    )
    assert guard.main([str(compose)]) == 1


@pytest.mark.parametrize(
    "line",
    [
        "# panic-drill is forbidden here (comment)",
        "    # dev-endpoints: never",
        '      --features "full-mining,p2p,hsm,panic-drill-extra"',
        "RUN echo my-panic-drill",
    ],
)
def test_non_tokens_and_comments_pass(tmp_path, line):
    ok = tmp_path / "ok.Dockerfile"
    ok.write_text(f"FROM scratch\n{line}\n", encoding="utf-8")
    assert guard.main([str(ok)]) == 0


def test_missing_file_fails(tmp_path):
    assert guard.main([str(tmp_path / "absent")]) == 1


def test_checker_list_is_added_never_replaces(tmp_path):
    checker = tmp_path / "check_release_endpoints.py"
    checker.write_text('SHIP_FORBIDDEN_FEATURES = ("future-drill",)\n', encoding="utf-8")
    assert guard.forbidden_features(checker) == ("dev-endpoints", "panic-drill", "future-drill")
    bad = tmp_path / "f.Dockerfile"
    bad.write_text('RUN cargo build --features "p2p,future-drill"\n', encoding="utf-8")
    assert guard.main(["--checker", str(checker), str(bad)]) == 1


def test_checker_without_list_fails_closed(tmp_path):
    checker = tmp_path / "check_release_endpoints.py"
    checker.write_text("X = 1\n", encoding="utf-8")
    assert guard.main(["--checker", str(checker), str(DOCKERFILE)]) == 1
