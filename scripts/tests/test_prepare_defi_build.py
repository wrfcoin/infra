"""Exercise the public-source/cache staging boundary without downloads."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "prepare-defi-build.py"
spec = importlib.util.spec_from_file_location("prepare_defi", SCRIPT)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PrepareDeFiTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="defi-cache-boundary-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "source"
        self.source.mkdir()
        archive = b"synthetic public crate archive"
        checksum = hashlib.sha256(archive).hexdigest()
        (self.source / "Cargo.toml").write_text('[workspace]\nmembers=[]\n')
        (self.source / "Cargo.lock").write_text(
            'version = 3\n[[package]]\nname="demo"\nversion="1.0.0"\n'
            'source="registry+https://github.com/rust-lang/crates.io-index"\n'
            f'checksum="{checksum}"\n')
        crate = self.source / "crates/defi-node/src"
        crate.mkdir(parents=True)
        (crate / "main.rs").write_text("fn main() {}\n")
        (self.source / "credentials.toml").write_text("synthetic-excluded-input\n")
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.source), "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Synthetic build fixture"], check=True)
        self.revision = subprocess.check_output(["git", "-C", str(self.source), "rev-parse", "HEAD"], text=True).strip()
        self.registry = self.root / "registry"
        index = self.registry / "index/index.crates.io-fixture"
        (index / ".cache/de/mo").mkdir(parents=True)
        (index / "config.json").write_text('{"dl":"https://static.crates.io/crates"}')
        (index / ".cache/de/mo/demo").write_bytes(b"synthetic public index record")
        self.archive = self.registry / "cache/index.crates.io-fixture/demo-1.0.0.crate"
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(archive)
        (self.registry / "credentials.toml").write_text("synthetic-excluded-cache-input\n")
        self.output = self.root / "output"

    def stage(self):
        return prepare.stage(self.source, self.registry, self.output, self.revision)

    def test_immutable_source_and_public_cache_only(self):
        (self.source / "crates/defi-node/src/main.rs").write_text("uncommitted working file\n")
        manifest = self.stage()
        self.assertEqual((self.output / "source/crates/defi-node/src/main.rs").read_text(), "fn main() {}\n")
        self.assertEqual(manifest["revision"], self.revision)
        self.assertFalse(list(self.output.rglob("credentials.toml")))
        for name, digest in manifest["sha256"].items():
            self.assertEqual(hashlib.sha256((self.output / name).read_bytes()).hexdigest(), digest)

    def test_corrupt_cached_archive_stops(self):
        self.archive.write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.stage()
        self.assertFalse((self.output / "manifest.json").exists())

    def test_absent_archive_is_reported_for_offline_build_to_decide(self):
        self.archive.unlink()
        self.assertEqual(self.stage()["missing_archives"], ["demo-1.0.0"])

    def test_existing_output_is_never_overwritten(self):
        self.output.mkdir()
        sentinel = self.output / "existing"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.stage()
        self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
