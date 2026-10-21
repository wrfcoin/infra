"""Real CLI/OpenSSL tests with temporary synthetic keys; no live hosts."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest


TOOL = Path(__file__).resolve().parents[2] / "testnet/join-archive.py"
spec = importlib.util.spec_from_file_location("join_archive", TOOL)
archive_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive_tool)


def crypto(*args):
    return subprocess.run(["openssl", *map(str, args)], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


@pytest.fixture
def packet(tmp_path):
    tmp_path.chmod(0o700)
    root = tmp_path / "files"
    root.mkdir()
    (root / "snapshot.tar.gz").write_bytes(b"synthetic compressed archive stand-in")
    (root / "extra.bin").write_bytes(b"second synthetic file")
    key = tmp_path / "archive.pem"
    crypto("genpkey", "-algorithm", "ED25519", "-out", key)
    key.chmod(0o600)
    public = crypto("pkey", "-in", key, "-pubout", "-outform", "DER")[-32:]
    pin = tmp_path / "archive.pub"
    pin.write_text(public.hex() + "\n")
    receipt = {
        "bundle_id": "synthetic-frozen-copy-1", "genesis_hash": "11" * 32,
        "network_id": "synthetic-testnet", "height": 12000,
        "tip_hash_hex": "22" * 32, "state_root_hex": "33" * 32,
        "core4_revision": "44" * 20, "infra_revision": "55" * 20,
        "source_image_id": "sha256:" + "66" * 32,
        "source_image_digest": "sha256:" + "77" * 32,
        "node_binary_sha256": "88" * 32, "created_at_utc": int(time.time()) - 10,
        "expires_at_utc": int(time.time()) + 3600, "checkpoint_format": 2,
        "protocol_version": 1, "schedule_digest": "99" * 32,
    }
    receipt_path = tmp_path / "receipt.json"
    receipt_path.write_text(json.dumps(receipt))
    return {"root": root, "key": key, "pin": pin, "receipt": receipt_path,
            "manifest": tmp_path / "manifest.json", "signature": tmp_path / "manifest.sig"}


def cli_args(packet, command, chain=777):
    args = [command, "--directory", str(packet["root"]),
            "--chain-id", str(chain), "--public-key-file", str(packet["pin"]),
            "--manifest", str(packet["manifest"]), "--signature", str(packet["signature"])]
    if command == "sign":
        args += ["--key-file", str(packet["key"]), "--receipt", str(packet["receipt"]),
                 "--file", "extra.bin", "--file", "snapshot.tar.gz"]
    return args


def cli(packet, command, extra=(), environ=None, chain=777):
    return subprocess.run([sys.executable, str(TOOL)] + cli_args(packet, command, chain) + list(extra), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=environ, timeout=10)


def signed(packet):
    result = cli(packet, "sign")
    assert result.returncode == 0, result.stderr.decode()


def refused(result):
    assert result.returncode != 0
    assert b"FAIL" in result.stderr


def test_real_round_trip_and_independent_openssl(packet, tmp_path):
    signed(packet)
    assert cli(packet, "verify").returncode == 0
    raw = packet["manifest"].read_bytes()
    manifest = json.loads(raw)
    assert manifest["chain_id"] == 777
    assert manifest["files"][1]["sha256"] == hashlib.sha256(
        (packet["root"] / "snapshot.tar.gz").read_bytes()).hexdigest()
    assert len(packet["signature"].read_bytes()) == 64
    # Construct the framing independently of production helpers, then verify
    # the real detached output with the OpenSSL CLI directly.
    message = tmp_path / "independent-preimage"
    message.write_bytes(b"wrfcoin.join_archive.v1" + b"\x00" + len(raw).to_bytes(8, "big") + raw)
    public = tmp_path / "independent-public.pem"
    public.write_bytes(crypto("pkey", "-in", packet["key"], "-pubout"))
    crypto("pkeyutl", "-verify", "-pubin", "-rawin", "-inkey", public,
           "-in", message, "-sigfile", packet["signature"])


def test_signing_reopens_validated_key_descriptor_at_eof(packet, monkeypatch):
    # Both real OpenSSL subprocesses reopen /proc/self/fd/N with their own
    # offset. Leave the validated parent descriptor at EOF throughout to
    # prove neither public-key extraction nor signing needs a parent rewind.
    real_open = archive_tool.open_regular
    real_openssl = archive_tool.openssl
    key_size = packet["key"].stat().st_size
    operations = []

    def open_at_eof(*args, **kwargs):
        fd = real_open(*args, **kwargs)
        if kwargs.get("secret"):
            os.lseek(fd, 0, os.SEEK_END)
        return fd

    def openssl_at_eof(args, pass_fds=()):
        if pass_fds:
            assert len(pass_fds) == 1
            assert os.lseek(pass_fds[0], 0, os.SEEK_CUR) == key_size
        result = real_openssl(args, pass_fds)
        if pass_fds:
            assert os.lseek(pass_fds[0], 0, os.SEEK_CUR) == key_size
            operations.append(args[0])
        return result

    monkeypatch.setattr(archive_tool, "open_regular", open_at_eof)
    monkeypatch.setattr(archive_tool, "openssl", openssl_at_eof)
    assert archive_tool.main(cli_args(packet, "sign")) == 0
    assert operations == ["pkey", "pkeyutl"]
    assert cli(packet, "verify").returncode == 0


@pytest.mark.parametrize("name", ["snapshot.tar.gz", "extra.bin"])
def test_tampered_file(packet, name):
    signed(packet)
    path = packet["root"] / name
    data = bytearray(path.read_bytes())
    data[0] ^= 1  # Same size: only the digest check catches this.
    path.write_bytes(data)
    refused(cli(packet, "verify"))


def test_wrong_chain(packet):
    signed(packet)
    refused(cli(packet, "verify", chain=778))


def test_wrong_independent_key(packet, tmp_path):
    signed(packet)
    wrong = tmp_path / "wrong.pem"
    crypto("genpkey", "-algorithm", "ED25519", "-out", wrong)
    packet["pin"].write_text(crypto("pkey", "-in", wrong, "-pubout", "-outform", "DER")[-32:].hex())
    refused(cli(packet, "verify"))


def test_signer_requires_matching_pin(packet):
    packet["pin"].write_text("aa" * 32)
    refused(cli(packet, "sign"))
    assert not packet["manifest"].exists()


def test_non_ed25519_key_refused(packet):
    crypto("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", packet["key"])
    packet["key"].chmod(0o600)
    refused(cli(packet, "sign"))
    assert not packet["manifest"].exists()


def test_oversized_receipt_refused(packet):
    packet["receipt"].write_bytes(b" " * 16385)
    refused(cli(packet, "sign"))
    assert not packet["manifest"].exists()


def test_missing_listed_file_refused(packet):
    signed(packet)
    (packet["root"] / "extra.bin").unlink()
    refused(cli(packet, "verify"))


@pytest.mark.parametrize("mode", [0o644, 0o640, 0o660, 0o604, 0o400, 0o700, 0o1600])
def test_key_permissions_refused(packet, mode):
    packet["key"].chmod(mode)
    refused(cli(packet, "sign"))
    assert not packet["manifest"].exists()


def test_symlink_key_refused(packet, tmp_path):
    link = tmp_path / "link.pem"
    link.symlink_to(packet["key"])
    packet["key"] = link
    refused(cli(packet, "sign"))


def test_hardlinked_key_refused(packet, tmp_path):
    os.link(packet["key"], tmp_path / "key-alias.pem")
    refused(cli(packet, "sign"))


@pytest.mark.parametrize("variable", ["WRFCOIN_JOIN_ARCHIVE_SIGNING_KEY", "WRFCOIN_JOIN_ARCHIVE_PRIVATE_KEY_HEX"])
def test_private_key_environment_refused_without_echo(packet, variable):
    test_env = dict(os.environ)
    marker = "synthetic-secret-must-never-appear"
    test_env[variable] = marker
    result = cli(packet, "sign", environ=test_env)
    refused(result)
    assert marker.encode() not in result.stdout + result.stderr
    assert not packet["manifest"].exists()


def test_bad_argv_not_echoed(packet):
    marker = "synthetic-secret-must-never-appear"
    result = cli(packet, "sign", extra=("--key-env", marker))
    refused(result)
    assert marker.encode() not in result.stdout + result.stderr


@pytest.mark.parametrize("target", ["manifest", "signature"])
def test_tampered_signed_bytes(packet, target):
    signed(packet)
    data = bytearray(packet[target].read_bytes())
    data[-1] ^= 1
    packet[target].write_bytes(data)
    refused(cli(packet, "verify"))


def test_missing_signature_unsigned_downgrade(packet):
    signed(packet)
    packet["signature"].unlink()
    refused(cli(packet, "verify"))


def test_no_output_overwrite(packet):
    signed(packet)
    before = packet["manifest"].read_bytes(), packet["signature"].read_bytes()
    refused(cli(packet, "sign"))
    assert before == (packet["manifest"].read_bytes(), packet["signature"].read_bytes())


@pytest.mark.parametrize("change", ["missing", "unknown", "float", "bool", "reversed_interval"])
def test_bad_receipt(packet, change):
    receipt = json.loads(packet["receipt"].read_text())
    if change == "missing":
        del receipt["node_binary_sha256"]
    elif change == "unknown":
        receipt["preimage"] = "caller-controlled-message"
    elif change == "float":
        receipt["height"] = 12000.0
    elif change == "bool":
        receipt["height"] = True
    else:
        receipt["expires_at_utc"] = receipt["created_at_utc"]
    packet["receipt"].write_text(json.dumps(receipt))
    refused(cli(packet, "sign"))
    assert not packet["manifest"].exists()


def test_duplicate_receipt_fields(packet):
    raw = packet["receipt"].read_text()
    packet["receipt"].write_text('{"height":12000,' + raw[1:])
    refused(cli(packet, "sign"))


@pytest.mark.parametrize("name", ["../escape", "/absolute", "sub/file", "snapshot.tar.gz"])
def test_unsafe_or_duplicate_file_name(packet, name):
    refused(cli(packet, "sign", extra=("--file", name)))


def test_symlink_archive_refused(packet, tmp_path):
    signed(packet)
    file = packet["root"] / "snapshot.tar.gz"
    other = tmp_path / "other"
    file.rename(other)
    file.symlink_to(other)
    refused(cli(packet, "verify"))


@pytest.mark.parametrize("framing", ["raw", "native", "little_endian"])
def test_cross_domain_or_wrong_framing_signature(packet, tmp_path, framing):
    signed(packet)
    raw = packet["manifest"].read_bytes()
    if framing == "raw":
        wrong_preimage = raw
    elif framing == "native":
        wrong_preimage = b"wrfcoin-sign-v1|snapshot_sync_payload.v2|" + raw
    else:
        wrong_preimage = b"wrfcoin.join_archive.v1\0" + len(raw).to_bytes(8, "little") + raw
    message = tmp_path / "wrong-preimage"
    message.write_bytes(wrong_preimage)
    packet["signature"].write_bytes(crypto("pkeyutl", "-sign", "-rawin", "-inkey",
                                          packet["key"], "-in", message))
    refused(cli(packet, "verify"))


def test_framing_fixed_vector():
    assert archive_tool.preimage(b"{}") == bytes.fromhex(
        "777266636f696e2e6a6f696e5f617263686976652e76310000000000000000027b7d")


def test_signed_noncanonical_and_unknown_schema_refused(packet, tmp_path):
    signed(packet)
    manifest = json.loads(packet["manifest"].read_bytes())
    for raw in (json.dumps(manifest, indent=2).encode(),
                archive_tool.canonical(dict(manifest, unexpected=True))):
        message = tmp_path / "schema-preimage"
        message.write_bytes(b"wrfcoin.join_archive.v1\0" + len(raw).to_bytes(8, "big") + raw)
        packet["manifest"].write_bytes(raw)
        packet["signature"].write_bytes(crypto("pkeyutl", "-sign", "-rawin", "-inkey",
                                              packet["key"], "-in", message))
        refused(cli(packet, "verify"))


@pytest.mark.parametrize("offset,accepted", [(-1, True), (0, False), (1, False)])
def test_expiry_boundary_with_injected_clock(packet, offset, accepted):
    signed(packet)
    expiry = json.loads(packet["manifest"].read_bytes())["receipt"]["expires_at_utc"]
    result = archive_tool.main(cli_args(packet, "verify"), clock=lambda: expiry + offset)
    assert (result == 0) is accepted


@pytest.mark.parametrize("skew,accepted", [(60, True), (61, False)])
def test_future_creation_skew_with_injected_clock(packet, skew, accepted):
    signed(packet)
    created = json.loads(packet["manifest"].read_bytes())["receipt"]["created_at_utc"]
    result = archive_tool.main(cli_args(packet, "verify"), clock=lambda: created - skew)
    assert (result == 0) is accepted


def test_expired_signature_refused_by_real_cli_clock(packet):
    receipt = json.loads(packet["receipt"].read_text())
    receipt.update(created_at_utc=1, expires_at_utc=2)
    packet["receipt"].write_text(json.dumps(receipt))
    # Produce a valid detached signature while the receipt is still current.
    assert archive_tool.main(cli_args(packet, "sign"), clock=lambda: 1) == 0
    result = cli(packet, "verify")
    refused(result)
    assert b"receipt expired" in result.stderr


def test_future_creation_refused_by_real_cli_clock(packet):
    receipt = json.loads(packet["receipt"].read_text())
    created = int(time.time()) + 3600
    receipt.update(created_at_utc=created, expires_at_utc=created + 3600)
    packet["receipt"].write_text(json.dumps(receipt))
    assert archive_tool.main(cli_args(packet, "sign"), clock=lambda: created) == 0
    result = cli(packet, "verify")
    refused(result)
    assert b"receipt creation is in the future" in result.stderr


def test_signing_refuses_any_future_creation(packet):
    receipt = json.loads(packet["receipt"].read_text())
    created = receipt["created_at_utc"]
    assert archive_tool.main(cli_args(packet, "sign"), clock=lambda: created - 1) == 1
    assert not packet["manifest"].exists()
    assert not packet["signature"].exists()


def test_signing_refuses_future_creation_real_cli(packet):
    receipt = json.loads(packet["receipt"].read_text())
    receipt.update(created_at_utc=int(time.time()) + 3600,
                   expires_at_utc=int(time.time()) + 7200)
    packet["receipt"].write_text(json.dumps(receipt))
    refused(cli(packet, "sign"))
    assert not packet["manifest"].exists()


@pytest.mark.parametrize("kind", ["file", "hidden", "nested", "empty_dir", "symlink", "fifo"])
def test_unlisted_staged_tree_refused(packet, kind):
    signed(packet)
    extra = packet["root"] / (".hidden" if kind == "hidden" else "injected")
    if kind in ("file", "hidden"):
        extra.write_bytes(b"unsigned")
    elif kind in ("nested", "empty_dir"):
        extra.mkdir()
        if kind == "nested":
            (extra / "payload.bin").write_bytes(b"unsigned nested")
    elif kind == "symlink":
        extra.symlink_to(packet["root"] / "snapshot.tar.gz")
    else:
        os.mkfifo(extra)
    refused(cli(packet, "verify"))


@pytest.mark.parametrize("mode", [0o755, 0o750, 0o770, 0o1700])
def test_key_parent_permissions_refused(packet, mode):
    packet["key"].parent.chmod(mode)
    refused(cli(packet, "sign"))
    assert not packet["manifest"].exists()


def test_key_parent_symlink_refused(packet, tmp_path):
    custody = tmp_path / "custody"
    custody.mkdir(mode=0o700)
    key = custody / "archive.pem"
    packet["key"].rename(key)
    alias = tmp_path / "alias"
    alias.symlink_to(custody, target_is_directory=True)
    packet["key"] = alias / "archive.pem"
    refused(cli(packet, "sign"))
