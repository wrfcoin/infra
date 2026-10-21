"""infra#1018: the post-cut block-1 gate. RED for the 09-13 cut's shape."""
import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "testnet/scripts/check-cut-block1.py"
SCHEDULE = "signing_v2@1,fixture_feature@50"  # synthetic
GOOD_LOG = "INFO boot\nSigning protocol v2 active for chain 777/testnet (#2123)\n"


def run(tmp_path, block, logs=(GOOD_LOG,), schedule=SCHEDULE, version="v2", raw=None):
    block_file = tmp_path / "block1.json"
    block_file.write_text(raw if raw is not None else json.dumps(block))
    cmd = [sys.executable, str(SCRIPT), "--block-json", str(block_file), "--expected-schedule", schedule,
           "--expected-version", version]
    for index, text in enumerate(logs):
        log = tmp_path / f"node{index}.log"
        log.write_text(text)
        cmd += ["--node-log", str(log)]
    return subprocess.run(cmd, capture_output=True, text=True)


def envelope(**metadata):
    return {"ok": True, "data": {"height": 1, "metadata": metadata}}


GOOD = envelope(protocol_activation_schedule=SCHEDULE, protocol_version="v2")


def test_good_cut_passes_envelope_and_bare(tmp_path):
    assert run(tmp_path, GOOD).returncode == 0
    assert run(tmp_path, GOOD["data"]).returncode == 0


def test_the_0913_cut_shape_fails(tmp_path):
    result = run(tmp_path, envelope(protocol_version="v1"), logs=("Signing protocol v1 active for chain x\n",))
    assert result.returncode == 1
    assert "lacks protocol_activation_schedule" in result.stderr
    assert "expected 'v2'" in result.stderr


def test_schedule_mismatch_fails_without_printing_it(tmp_path):
    result = run(tmp_path, envelope(protocol_activation_schedule="other@9", protocol_version="v2"))
    assert result.returncode == 1 and "differs from the intended schedule" in result.stderr
    assert "other@9" not in result.stderr and SCHEDULE not in result.stderr


def test_wrong_version_fails(tmp_path):
    assert run(tmp_path, envelope(protocol_activation_schedule=SCHEDULE, protocol_version="v1")).returncode == 1


def test_any_node_still_on_v1_fails(tmp_path):
    result = run(tmp_path, GOOD, logs=(GOOD_LOG, "Signing protocol v1 active for chain x\n"))
    assert result.returncode == 1 and "node1.log" in result.stderr


def test_last_line_wins_after_upgrade(tmp_path):
    log = "Signing protocol v1 active for chain x\nrestart\nSigning protocol v2 active for chain x\n"
    assert run(tmp_path, GOOD, logs=(log,)).returncode == 0
    assert run(tmp_path, GOOD, logs=("Signing protocol v2 active x\nSigning protocol v1 active x\n",)).returncode == 1


def test_log_without_line_fails(tmp_path):
    assert run(tmp_path, GOOD, logs=("nothing relevant\n",)).returncode == 1


def test_no_metadata_and_bad_json(tmp_path):
    assert run(tmp_path, {"ok": True, "data": {"height": 1}}).returncode == 1
    assert run(tmp_path, None, raw="{not json").returncode == 2


def test_empty_expected_schedule_is_a_usage_error(tmp_path):
    assert run(tmp_path, GOOD, schedule=" ").returncode == 2


def test_wrong_height_fails_even_with_matching_metadata(tmp_path):
    for height in (2, 0, 10):
        block = {"ok": True, "data": {"height": height, "metadata": GOOD["data"]["metadata"]}}
        result = run(tmp_path, block)
        assert result.returncode == 1 and f"height is {height}" in result.stderr


def test_missing_or_non_numeric_height_fails(tmp_path):
    md = GOOD["data"]["metadata"]
    for height in (None, True, "1", 1.0, [1]):
        data = {"metadata": md} if height is None else {"height": height, "metadata": md}
        result = run(tmp_path, {"ok": True, "data": data})
        assert result.returncode == 1 and "numeric height" in result.stderr, (height, result.stderr)
    assert run(tmp_path, {"metadata": md}).returncode == 1  # bare block without a height


def test_envelope_must_say_ok_true(tmp_path):
    md = GOOD["data"]["metadata"]
    for env in ({"ok": False, "data": {"height": 1, "metadata": md}},
                {"data": {"height": 1, "metadata": md}},
                {"ok": "true", "data": {"height": 1, "metadata": md}}):
        result = run(tmp_path, env)
        assert result.returncode == 1 and "ok:true" in result.stderr, env


def test_bare_height_one_block_still_passes(tmp_path):
    assert run(tmp_path, {"height": 1, "metadata": GOOD["data"]["metadata"]}).returncode == 0


def test_chain_888_defaults_to_v1_while_777_keeps_v2(tmp_path):
    import os
    block = tmp_path / 'block.json'
    log = tmp_path / 'node.log'
    block.write_text(json.dumps(envelope(protocol_activation_schedule=SCHEDULE, protocol_version='v1')))
    log.write_text('Signing protocol v1 active for chain 888/testnet\n')
    command = [sys.executable, str(SCRIPT), '--block-json', str(block),
               '--expected-schedule', SCHEDULE, '--node-log', str(log)]
    clean_env = {key: value for key, value in os.environ.items() if key != 'WRFCOIN_CHAIN_ID'}
    for args, env in [(['--chain-id', '888'], clean_env), ([], {**clean_env, 'WRFCOIN_CHAIN_ID': '888'})]:
        result = subprocess.run(command + args, env=env, capture_output=True, text=True)
        assert result.returncode == 0 and 'version=v1' in result.stdout, result.stderr
    result = subprocess.run(command + ['--chain-id', '777'], env=clean_env, capture_output=True, text=True)
    assert result.returncode == 1 and "expected 'v2'" in result.stderr
    # An explicit expectation remains authoritative for diagnostic controls.
    result = subprocess.run(command + ['--chain-id', '888', '--expected-version', 'v2'],
                            env=clean_env, capture_output=True, text=True)
    assert result.returncode == 1 and "expected 'v2'" in result.stderr
    for chain in ['888', 888]:
        block.write_text(json.dumps(envelope(chain_id=chain, protocol_activation_schedule=SCHEDULE,
                                             protocol_version='v1')))
        result = subprocess.run(command, env=clean_env, capture_output=True, text=True)
        assert result.returncode == 0 and 'version=v1' in result.stdout, result.stderr
