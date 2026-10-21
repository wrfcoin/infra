#!/usr/bin/env python3
"""Offline, detached Ed25519 archive-manifest signing and verification.

Linux/Python 3/OpenSSL 3; no network, Docker, key generation or restore.
See JOIN_ARCHIVE_TOOLING.md for the versioned byte contract and limits.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time


DOMAIN = b"wrfcoin.join_archive.v1\0"
SCHEMA = "wrfcoin.join_archive.detached.v1"
MAX_MANIFEST = 16384
MAX_FILES = 32
VERIFY_CLOCK_SKEW_SECONDS = 60
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
RECEIPT_FIELDS = {
    "bundle_id", "genesis_hash", "network_id", "height", "tip_hash_hex",
    "state_root_hex", "core4_revision", "infra_revision", "source_image_id",
    "source_image_digest", "node_binary_sha256", "created_at_utc",
    "expires_at_utc", "checkpoint_format", "protocol_version", "schedule_digest",
}


class Refused(ValueError):
    """Safe, fixed error text; never include input contents or key paths."""


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally reflects invalid values/unknown argv into stderr.
        self.exit(2, "JOIN_ARCHIVE=FAIL: invalid arguments; use --help\n")


def require(condition, message):
    if not condition:
        raise Refused(message)


def exact_fields(value, fields):
    require(type(value) is dict and set(value) == fields, "unexpected schema fields")


def uint(value):
    require(type(value) is int and 0 <= value < 2**64, "invalid unsigned integer")


def hex_digest(value):
    require(type(value) is str and HEX64.fullmatch(value), "invalid digest")


def validate_receipt(receipt):
    exact_fields(receipt, RECEIPT_FIELDS)
    for name in ("height", "created_at_utc", "expires_at_utc", "checkpoint_format", "protocol_version"):
        uint(receipt[name])
    require(receipt["expires_at_utc"] > receipt["created_at_utc"], "invalid receipt interval")
    for name in ("genesis_hash", "tip_hash_hex", "state_root_hex", "node_binary_sha256", "schedule_digest"):
        hex_digest(receipt[name])
    for name in ("core4_revision", "infra_revision"):
        require(type(receipt[name]) is str and re.fullmatch(r"[0-9a-f]{40}", receipt[name]), "invalid revision")
    for name in ("source_image_id", "source_image_digest"):
        require(type(receipt[name]) is str and re.fullmatch(r"sha256:[0-9a-f]{64}", receipt[name]), "invalid image digest")
    for name in ("bundle_id", "network_id"):
        require(type(receipt[name]) is str and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", receipt[name]), "invalid receipt identifier")


def file_name(name):
    # Root basenames only: no traversal, absolute paths, private host paths or directories.
    require(type(name) is str and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", name), "invalid file name")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON field")
        result[key] = value
    return result


def parse_json(raw):
    require(0 < len(raw) <= MAX_MANIFEST, "JSON size refused")
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise Refused("invalid JSON") from exc


def open_regular(path, secret=False, dir_fd=None):
    # Validate the opened descriptor, not a preceding pathname stat. Nonblocking
    # avoids hangs on a substituted FIFO. O_NOFOLLOW rejects final symlinks.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode), "regular file required")
        if secret:
            require(stat.S_IMODE(info.st_mode) == 0o600, "private key requires mode 0600")
            require(info.st_uid == os.geteuid() and info.st_nlink == 1, "private key ownership/link refused")
            require(0 < info.st_size <= 4096, "private key size refused")
        return fd
    except BaseException:
        os.close(fd)
        raise


def bounded_read(path, limit):
    fd = open_regular(path)
    with os.fdopen(fd, "rb") as stream:
        raw = stream.read(limit + 1)
    require(len(raw) <= limit, "file size refused")
    return raw


def pinned_key(path):
    raw = bounded_read(path, 65)
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    require(re.fullmatch(b"[0-9a-f]{64}", raw), "invalid public key pin")
    return bytes.fromhex(raw.decode("ascii"))


def walk_error(error):
    raise error


def file_records(directory, names, strict=False):
    require(1 <= len(names) <= MAX_FILES and len(set(names)) == len(names), "file count/duplicates refused")
    for name in names:
        file_name(name)
    # No nested paths; all opens stay relative to this already-open root.
    root_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if strict:
            # Walk relative to the validated root. The schema permits only
            # root files, so any directory (even empty) or symlink is refused.
            for _, directories, files, walk_fd in os.fwalk(
                    ".", dir_fd=root_fd, follow_symlinks=False,
                    onerror=walk_error):
                require(not directories and set(files) == set(names),
                        "staged tree differs from signed file list")
                for name in files:
                    require(stat.S_ISREG(os.stat(name, dir_fd=walk_fd,
                                                follow_symlinks=False).st_mode),
                            "staged regular files required")
        records = []
        for name in sorted(names):
            fd = open_regular(name, dir_fd=root_fd)
            with os.fdopen(fd, "rb") as stream:
                before = os.fstat(stream.fileno())
                digest, size = hashlib.sha256(), 0
                while block := stream.read(1024 * 1024):
                    digest.update(block)
                    size += len(block)
                after = os.fstat(stream.fileno())
            require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                    (after.st_size, after.st_mtime_ns, after.st_ctime_ns) and size == after.st_size,
                    "file changed while hashing")
            uint(size)
            records.append({"name": name, "sha256": digest.hexdigest(), "size_bytes": size})
        return records
    finally:
        os.close(root_fd)


def validate_manifest(manifest):
    exact_fields(manifest, {"schema", "chain_id", "receipt", "archive", "files"})
    require(manifest["schema"] == SCHEMA, "unsupported manifest schema")
    uint(manifest["chain_id"])
    validate_receipt(manifest["receipt"])
    files = manifest["files"]
    require(type(files) is list and 1 <= len(files) <= MAX_FILES, "invalid file list")
    names = []
    for entry in files:
        exact_fields(entry, {"name", "sha256", "size_bytes"})
        file_name(entry["name"])
        hex_digest(entry["sha256"])
        uint(entry["size_bytes"])
        names.append(entry["name"])
    require(names == sorted(set(names)), "file order/duplicates refused")
    require(manifest["archive"] == "snapshot.tar.gz" and manifest["archive"] in names,
            "snapshot archive required")


def preimage(raw):
    return DOMAIN + len(raw).to_bytes(8, "big") + raw


def openssl(args, pass_fds=()):
    # Suppress OpenSSL diagnostics: errors must never reflect secret input.
    result = subprocess.run(["openssl", *args], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, pass_fds=pass_fds, timeout=30)
    require(result.returncode == 0, "Ed25519 operation refused")
    return result.stdout


def verify_signature(raw, signature, key):
    require(len(signature) == 64, "invalid signature size")
    with tempfile.TemporaryDirectory(prefix="join-archive-verify-") as temp:
        root = Path(temp)
        (root / "public.der").write_bytes(SPKI_PREFIX + key)
        (root / "preimage").write_bytes(preimage(raw))
        (root / "signature").write_bytes(signature)
        openssl(["pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER",
                 "-inkey", str(root / "public.der"), "-in", str(root / "preimage"),
                 "-sigfile", str(root / "signature")])


def sign_bytes(raw, key_file, pin):
    # No env-backed private key. Inspect names only; never read/display values.
    require(not any(name.startswith("WRFCOIN_") and "JOIN_ARCHIVE" in name and
                    ("SIGNING_KEY" in name or "PRIVATE_KEY" in name or "SECRET" in name)
                    for name in os.environ), "private key environment refused")
    key_path = Path(key_file)
    parent_fd = os.open(key_path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parent = os.fstat(parent_fd)
        require(stat.S_IMODE(parent.st_mode) == 0o700 and parent.st_uid == os.geteuid(),
                "private key parent requires owned mode 0700")
        fd = open_regular(key_path.name, secret=True, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
    try:
        # OpenSSL reopens this validated descriptor through procfs with an
        # independent offset for each operation; no parent rewind is needed.
        key_ref = f"/proc/self/fd/{fd}"
        public = openssl(["pkey", "-in", key_ref, "-passin", "pass:", "-pubout", "-outform", "DER"], (fd,))
        require(public == SPKI_PREFIX + pin, "archive key does not match independent Ed25519 pin")
        with tempfile.TemporaryDirectory(prefix="join-archive-sign-") as temp:
            message = Path(temp) / "preimage"
            message.write_bytes(preimage(raw))
            signature = openssl(["pkeyutl", "-sign", "-rawin", "-inkey", key_ref,
                                 "-passin", "pass:", "-in", str(message)], (fd,))
        verify_signature(raw, signature, pin)
        return signature
    finally:
        os.close(fd)


def write_new(path, raw):
    # Never overwrite a preexisting manifest, signature, key or archive.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def check_receipt_clock(receipt, now, signing=False):
    skew = 0 if signing else VERIFY_CLOCK_SKEW_SECONDS
    require(receipt["created_at_utc"] <= now + skew, "receipt creation is in the future")
    require(now < receipt["expires_at_utc"], "receipt expired")


def main(argv=None, clock=time.time):
    parser = SafeParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("sign", "verify"):
        sub = commands.add_parser(command, allow_abbrev=False)
        sub.add_argument("--directory", required=True)
        sub.add_argument("--chain-id", required=True, type=int)
        sub.add_argument("--public-key-file", required=True)
        sub.add_argument("--manifest", required=True)
        sub.add_argument("--signature", required=True)
        if command == "sign":
            sub.add_argument("--key-file", required=True)
            sub.add_argument("--receipt", required=True)
            sub.add_argument("--file", action="append", required=True)
    args = parser.parse_args(argv)
    try:
        uint(args.chain_id)
        pin = pinned_key(args.public_key_file)
        if args.command == "sign":
            receipt = parse_json(bounded_read(args.receipt, MAX_MANIFEST))
            validate_receipt(receipt)
            check_receipt_clock(receipt, clock(), signing=True)
            manifest = {"schema": SCHEMA, "chain_id": args.chain_id, "receipt": receipt,
                        "archive": "snapshot.tar.gz", "files": file_records(args.directory, args.file)}
            validate_manifest(manifest)
            raw = canonical(manifest)
            require(len(raw) <= MAX_MANIFEST, "manifest size refused")
            signature = sign_bytes(raw, args.key_file, pin)
            # Deliberately not a publication transaction. A partial pair is
            # rejected by verify; owner staging/promotion is separate work.
            write_new(args.manifest, raw)
            write_new(args.signature, signature)
            print("JOIN_ARCHIVE_SIGN=PASS")
        else:
            raw = bounded_read(args.manifest, MAX_MANIFEST)
            signature = bounded_read(args.signature, 64)
            verify_signature(raw, signature, pin)  # Exact bytes BEFORE parsing.
            manifest = parse_json(raw)
            validate_manifest(manifest)
            require(raw == canonical(manifest), "noncanonical manifest refused")
            require(manifest["chain_id"] == args.chain_id, "chain identity mismatch")
            check_receipt_clock(manifest["receipt"], clock())
            actual = file_records(args.directory, [item["name"] for item in manifest["files"]], strict=True)
            require(actual == manifest["files"], "archive/file digest or size mismatch")
            print("JOIN_ARCHIVE_VERIFY=PASS")
        return 0
    except (Refused, OSError, subprocess.SubprocessError) as exc:
        message = str(exc) if isinstance(exc, Refused) else "local I/O or crypto operation refused"
        print(f"JOIN_ARCHIVE_{args.command.upper()}=FAIL: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
