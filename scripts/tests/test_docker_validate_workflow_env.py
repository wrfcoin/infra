"""Every compose render step in testnet-docker-validate.yml must supply the
variables its compose files require (infra#1064).

`${VAR:?}` guards interpolate across the whole file set; profiles do not scope
them (#762). So a render step fails if ANY file it names requires a variable the
step's environment does not provide. infra#1064 was exactly that:
docker-compose.oracle-attester.yml gained `${WRFCOIN_ATTESTER_NWS_STATION:?}`
(infra#986), the workflow was never updated, and the failure stayed invisible
because hosted runners are billing-VOID.

The workflow is path-filtered, so a later compose change can land without it
ever running. This test is collected by the unfiltered CT102 `scripts/tests`
job on every PR, which closes that gap statically. It needs no Docker.

Run: python3 -m pytest scripts/tests/test_docker_validate_workflow_env.py
"""
import pathlib
import re

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/testnet-docker-validate.yml"
RENDER_HELPER = ROOT / "testnet/tests/render-testnet-compose.sh"
REQUIRED = re.compile(r"\$\{([A-Z_][A-Z0-9_]*):\?")
FILE_ARG = re.compile(r"(?:^|\s)-f\s+(\S+)")


def _helper_exports():
    """Variables the shared render helper forces for every render."""
    return set(re.findall(r"^export ([A-Z_][A-Z0-9_]*)=", RENDER_HELPER.read_text(), re.M))


def _render_steps():
    workflow = yaml.safe_load(WORKFLOW.read_text())
    top_env = workflow.get("env") or {}
    for job_name, job in workflow["jobs"].items():
        job_env = job.get("env") or {}
        for step in job.get("steps") or []:
            run = step.get("run") or ""
            if "render-testnet-compose.sh" not in run:
                continue
            files = FILE_ARG.findall(run.replace("\\\n", " "))
            provided = set(top_env) | set(job_env) | set(step.get("env") or {})
            yield f"{job_name}: {step.get('name')}", files, provided


STEPS = list(_render_steps())


def test_workflow_has_render_steps():
    # Non-vacuous: the parser must find the render steps it is meant to check.
    assert len(STEPS) >= 2, STEPS


@pytest.mark.parametrize("label,files,provided", STEPS, ids=[s[0] for s in STEPS])
def test_render_step_supplies_every_required_variable(label, files, provided):
    assert files, f"{label}: no -f compose files found in the step"
    required = set()
    for rel in files:
        path = ROOT / rel
        assert path.is_file(), f"{label}: names a compose file that does not exist: {rel}"
        required |= set(REQUIRED.findall(path.read_text()))
    missing = sorted(required - provided - _helper_exports())
    assert not missing, (
        f"{label}: compose files {files} require {missing}, which the step's env does not "
        "provide. Add a validation-only value to the step env (infra#1064)."
    )


def test_compose_validate_uses_hosted_pr_runner():
    # Public-CI owner ruling: every pull-request job uses a hosted runner.
    jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
    for name, job in jobs.items():
        assert job["runs-on"] == "ubuntu-latest", f"{name} runs on {job['runs-on']}"
