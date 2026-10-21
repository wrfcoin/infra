"""Workstation outage controls: Docker and USB stat boundaries are doubles."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).parents[1] / "check-standby-usb.py"
NAMES = ("wrfcoin-testnet-node", "wrfcoin-testnet-oracle-attester")
PINS = ("/dev/bus/usb/001/002", "/dev/bus/usb/001/003")


@pytest.fixture
def probe(monkeypatch):
    assert SCRIPT.is_file(), "standby outage check is absent on main"
    spec = importlib.util.spec_from_file_location("standby_usb", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    documents = {
        name: {"name": "/" + name, "running": True, "status": "running", "exit_code": 0,
               "devices": [{"PathOnHost": pin, "PathInContainer": pin, "CgroupPermissions": "rwm"}]}
        for name, pin in zip(NAMES, PINS)
    }
    calls, stats = [], []

    def command(argv, **kwargs):
        calls.append((argv, kwargs))
        result = documents[argv[-1]]
        if isinstance(result, BaseException):
            raise result
        if isinstance(result, subprocess.CompletedProcess):
            return result
        return subprocess.CompletedProcess(argv, 0, json.dumps(result), "")

    def device_stat(device):
        stats.append(device)
        return SimpleNamespace(st_mode=stat.S_IFCHR | 0o600)

    monkeypatch.setattr(module.subprocess, "run", command)
    monkeypatch.setattr(module, "stat_device", device_stat)
    return module, documents, calls, stats


def alerts(capsys):
    captured = capsys.readouterr()
    assert not captured.out
    events = [json.loads(line) for line in captured.err.splitlines()]
    assert events and all(event["level"] == "CRITICAL" for event in events)
    assert all(event["check"] == "standby-usb" for event in events)
    return events


def test_healthy_checks_only_two_named_local_containers_and_exact_usb_pins(probe, capsys):
    module, _, calls, stats = probe
    assert module.main() == 0
    output = capsys.readouterr()
    assert json.loads(output.out) == {"level": "INFO", "check": "standby-usb", "status": "PASS"}
    assert not output.err
    assert [call[0][-1] for call in calls] == list(NAMES)
    for argv, kwargs in calls:
        assert argv[:6] == ["docker", "--host", "unix:///var/run/docker.sock", "container", "inspect", "--format"]
        assert argv[-2] == "--"
        assert "{{json .HostConfig.Devices}}" in argv[6]
        assert ".Config" not in argv[6] and ".State.Error" not in argv[6]
        assert kwargs["timeout"] == 5 and kwargs["capture_output"]
    assert stats == list(PINS)


@pytest.mark.parametrize("index,exit_code", [(0, 128), (1, 255)])
def test_stopped_node_or_attester_is_loud_and_nonzero(probe, capsys, index, exit_code):
    module, docs, _, _ = probe
    docs[NAMES[index]].update(running=False, status="exited", exit_code=exit_code)
    assert module.main() == 1
    event, = alerts(capsys)
    assert event["code"] == "CONTAINER_STOPPED" and event["container"] == NAMES[index]
    assert event["exit_code"] == exit_code


@pytest.mark.parametrize("status", ["created", "restarting", "paused", "dead"])
def test_non_running_states_do_not_report_pass(probe, capsys, status):
    module, docs, _, _ = probe
    docs[NAMES[0]]["status"] = status
    assert module.main() == 1
    assert alerts(capsys)[0]["code"] == "CONTAINER_STOPPED"


@pytest.mark.parametrize("error", [FileNotFoundError(), PermissionError()])
def test_missing_or_unreadable_pin_even_on_running_container(probe, monkeypatch, capsys, error):
    module, _, _, _ = probe

    def device_stat(device):
        if device == PINS[0]:
            raise error
        return SimpleNamespace(st_mode=stat.S_IFCHR)

    monkeypatch.setattr(module, "stat_device", device_stat)
    assert module.main() == 1
    event, = alerts(capsys)
    assert event["code"] == "USB_DEVICE_UNAVAILABLE" and event["device"] == PINS[0]


def test_outage_reports_both_stopped_containers_and_both_missing_devices(probe, monkeypatch, capsys):
    module, docs, _, _ = probe
    for name, code in zip(NAMES, [128, 255]):
        docs[name].update(running=False, status="exited", exit_code=code)

    def missing(_):
        raise FileNotFoundError()

    monkeypatch.setattr(module, "stat_device", missing)
    assert module.main() == 1
    events = alerts(capsys)
    assert [event["code"] for event in events].count("CONTAINER_STOPPED") == 2
    assert [event["code"] for event in events].count("USB_DEVICE_UNAVAILABLE") == 2


@pytest.mark.parametrize("mode", [stat.S_IFREG, stat.S_IFDIR])
def test_pin_must_be_a_character_device(probe, monkeypatch, capsys, mode):
    module, _, _, _ = probe
    monkeypatch.setattr(module, "stat_device", lambda _: SimpleNamespace(st_mode=mode))
    assert module.main() == 1
    assert {event["code"] for event in alerts(capsys)} == {"USB_DEVICE_UNAVAILABLE"}


@pytest.mark.parametrize("devices", [[], None, [{"PathOnHost": "/dev/bus/usb"}],
                                      [{"PathOnHost": "/dev/bus/usb/001/../../private"}],
                                      [{"PathOnHost": "/dev/other"}]])
def test_unpinned_or_invalid_usb_mapping_is_not_green(probe, capsys, devices):
    module, docs, _, stats = probe
    docs[NAMES[0]]["devices"] = devices
    assert module.main() == 1
    assert alerts(capsys)[0]["code"] == "USB_PIN_UNAVAILABLE"
    assert stats == [PINS[1]]


def test_whole_bus_mapping_with_explicit_expected_pins_is_healthy(probe, capsys):
    module, docs, _, stats = probe
    for document in docs.values():
        document["devices"] = [{"PathOnHost": "/dev/bus/usb"}]
    assert module.main(["--node-usb-device", PINS[0], "--attester-usb-device", PINS[1]]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "PASS"
    assert stats == list(PINS)


def test_missing_expected_device_under_whole_bus_is_loud(probe, monkeypatch, capsys):
    module, docs, _, _ = probe
    for document in docs.values():
        document["devices"] = [{"PathOnHost": "/dev/bus/usb"}]

    def missing(_):
        raise FileNotFoundError()

    monkeypatch.setattr(module, "stat_device", missing)
    assert module.main(["--node-usb-device", PINS[0], "--attester-usb-device", PINS[1]]) == 1
    events = alerts(capsys)
    assert [event["device"] for event in events] == list(PINS)
    assert {event["code"] for event in events} == {"USB_DEVICE_UNAVAILABLE"}


def test_expected_pin_must_be_mapped_into_the_container(probe, capsys):
    module, _, _, stats = probe
    assert module.main(["--node-usb-device", "/dev/bus/usb/002/001"]) == 1
    assert alerts(capsys)[0]["code"] == "USB_PIN_UNAVAILABLE"
    assert stats == [PINS[1]]


@pytest.mark.parametrize("result", [
    subprocess.CompletedProcess([], 1, "", "synthetic-private-upstream-detail"),
    subprocess.CompletedProcess([], 0, "invalid JSON synthetic-private-upstream-detail", ""),
    subprocess.TimeoutExpired("docker", 5), FileNotFoundError(),
    {"name": "/wrong-container", "running": True, "status": "running", "exit_code": 0, "devices": []},
    {"name": "/wrfcoin-testnet-node", "running": "false", "status": "running", "exit_code": 0, "devices": []},
    {"name": "/wrfcoin-testnet-node", "running": True, "status": [], "exit_code": 0, "devices": []},
    {"name": "/wrfcoin-testnet-node", "running": True, "status": "running", "exit_code": True, "devices": []},
    [],
])
def test_unknown_inspection_is_loud_without_upstream_output(probe, capsys, result):
    module, docs, calls, _ = probe
    docs[NAMES[0]] = result
    assert module.main() == 1
    event, = alerts(capsys)
    assert event["code"] == "CONTAINER_INSPECT_UNAVAILABLE"
    assert "synthetic-private" not in json.dumps(event)
    assert len(calls) == 2  # Still checks the other container.


@pytest.mark.parametrize("outage", [False, True])
@pytest.mark.parametrize("whole_bus", [False, True])
def test_actual_cli_exit_and_log_with_executable_and_usb_doubles(tmp_path, outage, whole_bus):
    docs = {name: {"name": "/" + name, "running": not outage,
                   "status": "exited" if outage else "running", "exit_code": code if outage else 0,
                   "devices": [{"PathOnHost": "/dev/bus/usb" if whole_bus else pin}]}
            for name, pin, code in zip(NAMES, PINS, [128, 255])}
    fixture = tmp_path / "fixture.json"
    fixture.write_text(json.dumps({"documents": docs, "missing": outage}))
    docker = tmp_path / "docker"
    docker.write_text(f"#!{sys.executable}\n" +
                      "import json, os, sys\n"
                      "with open(os.environ['STANDBY_FIXTURE']) as f: data = json.load(f)\n"
                      "print(json.dumps(data['documents'][sys.argv[-1]]))\n")
    docker.chmod(0o755)
    wrapper = tmp_path / "double-stat.py"
    wrapper.write_text(
        "import json, os, runpy, stat, sys\n"
        "from types import SimpleNamespace\n"
        "with open(os.environ['STANDBY_FIXTURE']) as f: data = json.load(f)\n"
        "original = os.stat\n"
        "def double(path, *args, **kwargs):\n"
        "    if isinstance(path, str) and path.startswith('/dev/bus/usb/'):\n"
        "        if data['missing']: raise FileNotFoundError()\n"
        "        return SimpleNamespace(st_mode=stat.S_IFCHR)\n"
        "    return original(path, *args, **kwargs)\n"
        "os.stat = double\n"
        "script = sys.argv[1]\n"
        "sys.argv = sys.argv[1:]\n"
        "runpy.run_path(script, run_name='__main__')\n")
    argv = [sys.executable, str(wrapper), str(SCRIPT)]
    if whole_bus:
        argv += ["--node-usb-device", PINS[0], "--attester-usb-device", PINS[1]]
    result = subprocess.run(argv,
                            env={**os.environ, "PATH": str(tmp_path), "STANDBY_FIXTURE": str(fixture)},
                            text=True, capture_output=True, timeout=10)
    assert result.returncode == int(outage), result.stderr
    if outage:
        assert not result.stdout
        events = [json.loads(line) for line in result.stderr.splitlines()]
        assert len(events) == 4 and all(event["level"] == "CRITICAL" for event in events)
        assert [event["code"] for event in events].count("CONTAINER_STOPPED") == 2
        assert [event["code"] for event in events].count("USB_DEVICE_UNAVAILABLE") == 2
    else:
        assert json.loads(result.stdout)["status"] == "PASS" and not result.stderr
