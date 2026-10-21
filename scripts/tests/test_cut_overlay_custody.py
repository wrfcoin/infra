"""Execute the public cut renderer/checker using synthetic pins only."""
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
WRITER = "testnet/scripts/render-cut-overlay.sh"
HELPER = "scripts/cut-overlay-custody.py"
PIN = "1" * 64
FAUCET = "0x" + "2" * 40


def invoke(pins, overlay, check=False, root=ROOT):
    args = ["bash", str(root / WRITER), "--pins", str(pins), "--out", str(overlay)]
    if check:
        args.append("--check")
    return subprocess.run(args, text=True, capture_output=True, timeout=10)


def make_case(tmp_path, root=ROOT):
    pins = tmp_path / "synthetic-pins.env"
    overlay = tmp_path / "docker-compose.cut.yml"
    pins.write_text(f"WRFCOIN_CUT_GENESIS_HASH={PIN}\n")
    result = invoke(pins, overlay, root=root)
    assert result.returncode == 0, result.stderr
    return pins, overlay, Path(str(overlay) + ".custody.json")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rejected(pins, overlay, root=ROOT):
    paths = [pins, overlay, Path(str(overlay) + ".custody.json")]
    before = {p: p.read_bytes() for p in paths if p.is_file()}
    result = invoke(pins, overlay, check=True, root=root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "CUT_OVERLAY=FAIL" in result.stderr
    assert before == {p: p.read_bytes() for p in before}, "check must never repair inputs"


def test_record_binds_writer_inputs_and_overlay(tmp_path):
    pins, overlay, record = make_case(tmp_path)
    assert record.exists(), "renderer must emit its custody record"
    data = json.loads(record.read_text())
    assert data == {
        "schema": 1, "writer": WRITER, "writer_sha256": digest(ROOT / WRITER),
        "checker_sha256": digest(ROOT / HELPER), "pins_sha256": digest(pins),
        "overlay_sha256": digest(overlay),
    }
    assert record.stat().st_mode & 0o777 == 0o600
    before = (overlay.read_bytes(), record.read_bytes())
    assert invoke(pins, overlay, check=True).returncode == 0
    assert invoke(pins, overlay).returncode == 0
    assert before == (overlay.read_bytes(), record.read_bytes())


@pytest.mark.parametrize("change", ["service", "append", "duplicate", "comment"])
def test_matching_line_cannot_authenticate_other_overlay_bytes(tmp_path, change):
    pins, overlay, _ = make_case(tmp_path)
    text = overlay.read_text()
    if change == "service":
        text = text.replace("wrfcoin-node:", "unrelated-service:")
    elif change == "append":
        text += "    command: ['unreviewed']\n"
    elif change == "duplicate":
        text += f"      WRFCOIN_GENESIS_HASH: '{'3' * 64}'\n"
    else:
        text = text.replace("      WRFCOIN_GENESIS_HASH:", "      # WRFCOIN_GENESIS_HASH:")
    overlay.write_text(text)
    rejected(pins, overlay)


def test_checksum_rewrite_cannot_authenticate_noncanonical_service(tmp_path):
    pins, overlay, record = make_case(tmp_path)
    overlay.write_text(overlay.read_text().replace("wrfcoin-node:", "unrelated-service:"))
    assert record.exists()
    data = json.loads(record.read_text())
    data["overlay_sha256"] = digest(overlay)
    record.write_text(json.dumps(data))
    rejected(pins, overlay)


@pytest.mark.parametrize("change", [
    "missing", "json", "schema", "writer", "pins_sha256", "overlay_sha256", "extra",
    "duplicate", "oversized", "boolean", "list",
])
def test_missing_or_tampered_record_is_refused(tmp_path, change):
    pins, overlay, record = make_case(tmp_path)
    assert record.exists()
    if change == "missing":
        record.unlink()
    elif change == "json":
        record.write_text("{")
    elif change == "duplicate":
        record.write_text(record.read_text().replace('"schema": 1', '"schema": 1, "schema": 1'))
    elif change == "oversized":
        record.write_text(record.read_text() + " " * 4096)
    elif change == "boolean":
        record.write_text(record.read_text().replace('"schema": 1', '"schema": true'))
    elif change == "list":
        record.write_text("[]")
    else:
        data = json.loads(record.read_text())
        data[change] = "unreviewed"
        record.write_text(json.dumps(data))
    rejected(pins, overlay)


def test_any_reviewed_pin_bytes_change_invalidates_record(tmp_path):
    pins, overlay, _ = make_case(tmp_path)
    pins.write_text(pins.read_text() + "# a different reviewed source\n")
    rejected(pins, overlay)
    assert invoke(pins, overlay).returncode == 0
    assert invoke(pins, overlay, check=True).returncode == 0


@pytest.mark.parametrize("relative", [WRITER, HELPER])
def test_generator_upgrade_requires_explicit_owner_rerender(tmp_path, relative):
    copy = tmp_path / "repo"
    for file in [WRITER, HELPER]:
        target = copy / file
        target.parent.mkdir(parents=True, exist_ok=True)
        if (ROOT / file).exists():
            shutil.copyfile(ROOT / file, target)
    pins, overlay, _ = make_case(tmp_path, root=copy)
    with (copy / relative).open("a") as handle:
        handle.write("\n# synthetic new generator revision\n")
    rejected(pins, overlay, root=copy)


def test_faucet_value_stays_out_of_record_and_logs(tmp_path):
    pins, overlay, record = make_case(tmp_path)
    pins.write_text(pins.read_text() + f"WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS='{FAUCET}'\n")
    result = invoke(pins, overlay)
    assert result.returncode == 0
    assert record.exists()
    assert FAUCET not in record.read_text() + result.stdout + result.stderr
    result = invoke(pins, overlay, check=True)
    assert result.returncode == 0
    assert FAUCET not in result.stdout + result.stderr


def test_copying_pair_to_release_directory_retains_custody(tmp_path):
    pins, overlay, record = make_case(tmp_path)
    assert record.exists()
    staged = tmp_path / "release with spaces"
    staged.mkdir()
    for source in [pins, overlay, record]:
        shutil.copyfile(source, staged / source.name)
    assert invoke(staged / pins.name, staged / overlay.name, check=True).returncode == 0


@pytest.mark.parametrize("which", ["pins", "overlay", "record"])
def test_symlink_inputs_are_refused(tmp_path, which):
    pins, overlay, record = make_case(tmp_path)
    assert record.exists()
    path = {"pins": pins, "overlay": overlay, "record": record}[which]
    target = tmp_path / "indirect"
    path.rename(target)
    path.symlink_to(target)
    rejected(pins, overlay)
