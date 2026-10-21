#!/usr/bin/env python3
"""Read-only workstation node/attester and pinned USB check (Refs infra#970)."""
import argparse
import json
from os import stat as stat_device
import re
import stat
import subprocess
import sys

CONTAINERS = ("wrfcoin-testnet-node", "wrfcoin-testnet-oracle-attester")
USB_PIN = re.compile(r"/dev/bus/usb/[0-9]{3}/[0-9]{3}\Z")
INSPECT_FORMAT = (
    '{"name":{{json .Name}},"running":{{json .State.Running}},'
    '"status":{{json .State.Status}},"exit_code":{{json .State.ExitCode}},'
    '"devices":{{json .HostConfig.Devices}}}'
)


def inspect_container(name):
    """Select only state/pins, never container env, health logs or daemon errors."""
    try:
        result = subprocess.run([
            "docker", "--host", "unix:///var/run/docker.sock", "container", "inspect",
            "--format", INSPECT_FORMAT, "--", name,
        ], capture_output=True, text=True, timeout=5, check=False)
        if result.returncode != 0 or len(result.stdout) > 65536:
            return None
        document = json.loads(result.stdout)
        if (not isinstance(document, dict) or document.get("name") != "/" + name
                or type(document.get("running")) is not bool
                or not isinstance(document.get("status"), str)
                or document.get("status") not in {
                    "created", "running", "paused", "restarting", "removing", "exited", "dead"}
                or type(document.get("exit_code")) is not int
                or not 0 <= document["exit_code"] <= 255):
            return None
        return document
    except (OSError, subprocess.TimeoutExpired, ValueError, UnicodeError):
        return None


def usb_pins(devices, expected=()):
    """Check configured expectations under whole-bus or exact source mappings."""
    if not isinstance(devices, list) or len(devices) > 32:
        return None
    pins = set()
    whole_bus = False
    for device in devices:
        if not isinstance(device, dict) or not isinstance(device.get("PathOnHost"), str):
            return None
        source = device["PathOnHost"]
        if source == "/dev/bus/usb":
            whole_bus = True
        elif source.startswith("/dev/bus/usb/"):
            if not USB_PIN.fullmatch(source):
                return None
            pins.add(source)
    if not whole_bus and not set(expected).issubset(pins):
        return None
    pins.update(expected)
    return sorted(pins) or None


def alarm(name, code, **fields):
    print(json.dumps({"level": "CRITICAL", "check": "standby-usb", "container": name,
                      "code": code, **fields}, sort_keys=True), file=sys.stderr, flush=True)


def device_pin(value):
    if not USB_PIN.fullmatch(value):
        raise argparse.ArgumentTypeError("Expected an exact /dev/bus/usb/BBB/DDD source path")
    return value


def main(argv=()):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node-usb-device", action="append", type=device_pin, default=[],
                        help="expected node USB source pin (required for whole-bus mapping)")
    parser.add_argument("--attester-usb-device", action="append", type=device_pin, default=[],
                        help="expected attester USB source pin (required for whole-bus mapping)")
    arguments = parser.parse_args(argv)
    expected = dict(zip(CONTAINERS, (arguments.node_usb_device, arguments.attester_usb_device)))
    failed = False
    for name in CONTAINERS:
        document = inspect_container(name)
        if document is None:
            alarm(name, "CONTAINER_INSPECT_UNAVAILABLE")
            failed = True
            continue
        if not document["running"] or document["status"] != "running":
            alarm(name, "CONTAINER_STOPPED", status=document["status"], exit_code=document["exit_code"])
            failed = True
        pins = usb_pins(document.get("devices"), expected[name])
        if pins is None:
            alarm(name, "USB_PIN_UNAVAILABLE")
            failed = True
            continue
        for device in pins:
            try:
                available = stat.S_ISCHR(stat_device(device).st_mode)
            except OSError:
                available = False
            if not available:
                alarm(name, "USB_DEVICE_UNAVAILABLE", device=device)
                failed = True
    if not failed:
        print(json.dumps({"level": "INFO", "check": "standby-usb", "status": "PASS"}), flush=True)
    return int(failed)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
