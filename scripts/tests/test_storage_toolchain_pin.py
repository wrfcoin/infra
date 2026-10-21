"""Coupling guard: Dockerfile.storage's Rust builder vs storage-providers' CI toolchain.

storage-providers pins `rust-toolchain.toml` (channel 1.88.0) so CI checks what
ships, but this Dockerfile's builder never reads that file: it gets its compiler
from the `rust:<major.minor>-bookworm@sha256:...` tag. The two repos cannot see
each other in CI, so both assert the same constant instead:

  - here, against the Dockerfile's rust tag
  - in wrfcoin/storage-providers `crates/storage-node/tests/toolchain_pin.rs`,
    against rust-toolchain.toml

To bump Rust: change the Dockerfile tag+digest, the toml, and BOTH constants.
"""
from pathlib import Path
import re

ROOT = Path(__file__).parents[2]
DOCKERFILE = ROOT / "infra/docker/Dockerfile.storage"

# Must equal storage-providers rust-toolchain.toml channel major.minor.
STORAGE_PROVIDERS_RUST_MINOR = "1.88"


def builder_rust_minor(text):
    m = re.search(r"^FROM\s+rust:(\d+\.\d+)(?:\.\d+)?-\S+\s+AS\s+builder", text, re.M)
    assert m, "no `FROM rust:<ver>... AS builder` stage found"
    return m.group(1)


def test_dockerfile_builder_matches_storage_providers_toolchain():
    assert builder_rust_minor(DOCKERFILE.read_text()) == STORAGE_PROVIDERS_RUST_MINOR, (
        "Dockerfile.storage rust builder drifted from storage-providers "
        "rust-toolchain.toml; update both repos' constants together"
    )


def test_parser_detects_a_drifted_builder():
    drifted = "FROM rust:0.1-bookworm@sha256:abc AS builder\n"
    assert builder_rust_minor(drifted) == "0.1"
