"""Keep repeated PR pushes from multiplying CT102 work (Refs infra#1113)."""
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = (
    "alert-rules-gate.yml",
    "alignment-gate.yml",
    "dependabot-coverage.yml",
    "node-image-ship-guard.yml",
    "public-exposure-edge-gate.yml",
    "scripts-tests.yml",
    "testnet-docker-validate.yml",
)
GROUP = (
    "${{ github.workflow }}-${{ github.event_name == 'pull_request' && "
    "format('pr-{0}', github.event.pull_request.number) || "
    "format('run-{0}', github.run_id) }}"
)
CANCEL = "${{ github.event_name == 'pull_request' }}"


@pytest.mark.parametrize("filename", WORKFLOWS)
def test_supersession_is_scoped_to_one_pr_and_preserves_other_events(filename):
    workflow = yaml.safe_load((ROOT / ".github/workflows" / filename).read_text())
    concurrency = workflow.get("concurrency", {})
    # The explicit expressions form the policy: workflows and PR numbers scope
    # cancellation; run IDs isolate every push/main/dispatch/schedule event,
    # including pending jobs (GitHub can evict a pending job even when cancel=false).
    assert concurrency.get("group") == GROUP
    assert concurrency.get("cancel-in-progress") == CANCEL
