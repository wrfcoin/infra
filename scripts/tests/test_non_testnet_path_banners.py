"""The Kubernetes and Terraform material is not the testnet deployment path.

The testnet is built locally from source and deployed from testnet/;
no registry pushes. The READMEs used to tell a
reader to `kubectl apply` and `terraform apply` as the quick start, which reads
as the way to deploy this network. Every place that carries those commands must
say they are not the testnet path, and the two directories must say so too.

Run: python3 -m pytest scripts/tests/test_non_testnet_path_banners.py
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
MARKER = "NOT THE TESTNET DEPLOYMENT PATH"


def _read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def _section(text: str, heading: str) -> str:
    """Body of the markdown section that starts at `heading` up to the next heading."""
    start = text.index(heading)
    rest = text[start + len(heading):]
    for line_start in range(len(rest)):
        if rest.startswith("\n#", line_start):
            return rest[:line_start]
    return rest


def test_root_readme_banners_the_kubernetes_and_terraform_quick_starts():
    text = _read("README.md")
    assert "Kubernetes and Terraform" in text
    assert "reference material, not the active testnet deployment path" in text
    for section in re.split(r"(?m)^#{1,6} ", text):
        if re.search(r"\b(?:kubectl|terraform)\s+apply\b", section):
            assert MARKER in section, "deployment command needs a local non-testnet banner"


def test_infra_readme_banners_its_kubernetes_and_terraform_sections():
    text = _read("infra/README.md")
    for heading in ("### Kubernetes Deployment", "### Terraform Infrastructure"):
        assert MARKER in _section(text, heading), heading


def test_directories_carry_their_own_banner():
    for rel in ("infra/terraform/README.md", "infra/k8s/README.md"):
        path = ROOT / rel
        assert path.is_file(), f"{rel} is missing"
        body = path.read_text(encoding="utf-8")
        assert MARKER in body, rel
        assert "testnet/" in body, rel
