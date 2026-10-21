"""Offline CLI controls: synthetic Git checkouts and a read-only Docker transport."""
import copy
import json
import os
from pathlib import Path
import subprocess
import shutil

import pytest

SCRIPT = Path(__file__).parents[2] / "testnet/scripts/image-revisions.py"
LABEL = "org.opencontainers.image.revision"


@pytest.fixture
def rig(tmp_path):
    root = tmp_path / "workspace"
    pins = {}
    for repo in ("infra", "core4", "backend", "frontend", "oracle-reference", "storage-providers"):
        path = root / repo
        path.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(path)], check=True)
        (path / "source").write_text(repo)
        subprocess.run(["git", "-C", str(path), "add", "."], check=True)
        subprocess.run(["git", "-C", str(path), "-c", "user.name=Test", "-c",
                        "user.email=test@example.invalid", "commit", "-qm", "synthetic"], check=True)
        pins[repo] = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    builds = {
        "node": (root, "infra/infra/docker/Dockerfile.core", "core4"),
        "backend": (root, "infra/infra/docker/Dockerfile.backend-api", "backend"),
        "frontend": (root, "infra/testnet/Dockerfile.frontend", "frontend"),
        "helper": (root / "infra/testnet", "services/container-health-watch/Dockerfile", "infra"),
        "reference": (root / "oracle-reference", "Dockerfile", "oracle-reference"),
        "storage": (root, "infra/infra/docker/Dockerfile.storage", "storage-providers"),
    }
    render = {"services": {}}
    for name, (context, dockerfile, repo) in builds.items():
        path = context / dockerfile
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("FROM scratch\n")
        render["services"][name] = {"image": f"wrfcoin/{name}:synthetic", "build": {
            "context": str(context), "dockerfile": dockerfile,
            "args": {"KEEP": "sentinel"}}}
    # Track Dockerfiles in the appropriate checkout, preserving clean source.
    for repo in pins:
        path = root / repo
        subprocess.run(["git", "-C", str(path), "add", "."], check=True)
        subprocess.run(["git", "-C", str(path), "-c", "user.name=Test", "-c",
                        "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "recipes"], check=True)
        pins[repo] = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    render["services"]["alias"] = {"image": "wrfcoin/node:synthetic"}
    render["services"]["redis"] = {"image": "redis:synthetic"}
    pinfile, renderfile = tmp_path / "pins.json", tmp_path / "render.json"
    pinfile.write_text(json.dumps(pins))
    renderfile.write_text(json.dumps(render))
    binpath = tmp_path / "bin"
    binpath.mkdir()
    transport = binpath / "docker"
    datafile, commands = tmp_path / "docker.json", tmp_path / "commands"
    transport.write_text("#!/usr/bin/env python3\n" +
        "import json,os,sys\nfrom pathlib import Path\n" +
        f"p=Path({str(datafile)!r}); d=json.loads(p.read_text()); a=sys.argv[1:]\n" +
        f"with open({str(commands)!r},'a') as f:f.write(json.dumps(a)+'\\n')\n" +
        "if a[:2]==['ps','--filter']: print('\\n'.join(d['containers'])); sys.exit()\n" +
        "if a[:2]==['container','inspect']: print(json.dumps(d['containers'][a[-1]])); sys.exit()\n" +
        "if a[:2]==['image','inspect']: print(json.dumps(d['images'][a[-1]])); sys.exit()\n" +
        "sys.exit(99)\n")
    transport.chmod(0o755)
    image = "sha256:" + "a" * 64
    cid = "b" * 64
    fixture = {"containers": {cid: {"id": cid, "image": image, "running": True,
        "project": "synthetic", "service": "node", "revision": pins["core4"]}},
        "images": {image: {"id": image, "revision": pins["core4"]}}}
    datafile, commands = tmp_path / "docker.json", tmp_path / "commands"
    datafile.write_text(json.dumps(fixture))
    env = dict(os.environ, PATH=str(binpath) + os.pathsep + os.environ["PATH"],
               FIXTURE=str(datafile), COMMANDS=str(commands))
    def run(mode="prepare", **changes):
        for key, value in changes.items():
            if key == "pins": pinfile.write_text(json.dumps(value))
            if key == "render": renderfile.write_text(json.dumps(value))
            if key == "fixture": datafile.write_text(json.dumps(value))
        argv = ["python3", str(SCRIPT), mode, "--root", str(root),
                "--pins", str(pinfile), "--render", str(renderfile)]
        if mode == "check": argv += ["--project", "synthetic", "--require", "node"]
        return subprocess.run(argv, env=env, text=True, capture_output=True)
    return root, pins, render, fixture, run, commands


def test_prepare_covers_all_builds_with_exact_arg_and_image_label(rig):
    _, pins, render, _, run, _ = rig
    result = run()
    assert result.returncode == 0, result.stderr
    overlay = json.loads(result.stdout)["services"]
    assert set(overlay) == set(render["services"]) - {"alias", "redis"}
    for service, repo in {"node": "core4", "backend": "backend", "frontend": "frontend",
                          "helper": "infra", "reference": "oracle-reference",
                          "storage": "storage-providers"}.items():
        assert overlay[service] == {"build": {"args": {"WRFCOIN_BUILD_REVISION": pins[repo]},
                                              "labels": {LABEL: pins[repo]}}}


@pytest.mark.parametrize("case", ["missing", "short", "placeholder", "wrong", "duplicate"])
def test_bad_pins_refuse_without_output(rig, case):
    root, pins, _, _, run, _ = rig
    pins = dict(pins)
    if case == "missing": pins.pop("core4")
    elif case == "short": pins["core4"] = pins["core4"][:12]
    elif case == "placeholder": pins["core4"] = "@CORE@"
    elif case == "wrong": pins["core4"] = "0" * 40
    else:
        (root.parent / "pins.json").write_text('{"core4":"' + pins['core4'] + '","core4":"' + pins['core4'] + '"}')
    result = run() if case == "duplicate" else run(pins=pins)
    assert result.returncode != 0 and not result.stdout


def test_dirty_source_refuses(rig):
    root, _, _, _, run, _ = rig
    (root / "core4/source").write_text("different")
    result = run()
    assert result.returncode != 0 and not result.stdout


@pytest.mark.parametrize("case", ["empty", "unknown_recipe", "outside", "inline", "image_collision"])
def test_bad_render_refuses(rig, case):
    _, _, render, _, run, _ = rig
    render = copy.deepcopy(render)
    if case == "empty": render["services"] = {}
    elif case == "unknown_recipe": render["services"]["node"]["build"]["dockerfile"] = "infra/unknown"
    elif case == "outside": render["services"]["helper"]["build"]["context"] = "/tmp/unowned"
    elif case == "inline": render["services"]["node"]["build"]["dockerfile_inline"] = "FROM scratch"
    else: render["services"]["backend"]["image"] = render["services"]["node"]["image"]
    result = run(render=render)
    assert result.returncode != 0 and not result.stdout


def test_runtime_checks_container_and_actual_image_read_only(rig):
    _, _, _, _, run, commands = rig
    result = run("check")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["checked"] == ["node"]
    calls = [json.loads(s) for s in commands.read_text().splitlines()]
    assert calls[0] == ["ps", "--filter", "label=com.docker.compose.project=synthetic", "--quiet", "--no-trunc"]
    assert calls[-1] == calls[0]
    assert [x[:2] for x in calls[1:-1]] == [["container", "inspect"], ["image", "inspect"], ["container", "inspect"]]
    assert all("--format" in x for x in calls[1:-1])
    assert all(".Config.Env" not in str(x) for x in calls)


@pytest.mark.parametrize("case", ["empty", "stopped", "container_revision", "wrong_container_revision", "image_revision", "missing_image_revision", "image_identity",
                                  "project", "missing_service", "unknown_service", "malformed_id"])
def test_runtime_bad_metadata_refuses(rig, case):
    _, _, _, fixture, run, _ = rig
    fixture = copy.deepcopy(fixture)
    c = next(iter(fixture["containers"].values()))
    i = next(iter(fixture["images"].values()))
    if case == "empty": fixture["containers"] = {}
    elif case == "stopped": c["running"] = False
    elif case == "container_revision": c["revision"] = None
    elif case == "wrong_container_revision": c["revision"] = "0" * 40
    elif case == "missing_image_revision": i["revision"] = None
    elif case == "image_revision": i["revision"] = "0" * 40
    elif case == "image_identity": i["id"] = "sha256:" + "c" * 64
    elif case == "project": c["project"] = "foreign"
    elif case == "missing_service": c["service"] = "helper"
    elif case == "unknown_service": c["service"] = "unlisted"
    else: fixture["containers"] = {"--unsafe": c}
    result = run("check", fixture=fixture)
    assert result.returncode != 0 and not result.stdout


def test_runtime_alias_uses_same_source_pin(rig):
    _, _, _, fixture, run, _ = rig
    fixture = copy.deepcopy(fixture)
    c = copy.deepcopy(next(iter(fixture["containers"].values())))
    c["id"] = "c" * 64
    c["service"] = "alias"
    fixture["containers"][c["id"]] = c
    result = run("check", fixture=fixture)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["checked"] == ["alias", "node"]


def test_recipe_source_must_also_be_pinned_clean(rig):
    root, _, _, _, run, _ = rig
    (root / "infra/infra/docker/Dockerfile.core").write_text("FROM changed\n")
    result = run()
    assert result.returncode != 0 and not result.stdout


def test_metadata_transport_failure_is_not_pass(rig):
    root, _, _, _, run, _ = rig
    (root.parent / "bin/docker").write_text("#!/bin/sh\necho secret-sentinel >&2\nexit 7\n")
    result = run("check")
    assert result.returncode != 0 and not result.stdout
    assert "secret-sentinel" not in result.stderr


def test_real_compose_merge_keeps_every_other_field(rig):
    root, pins, _, _, run, _ = rig
    repo = SCRIPT.parents[2]
    target = root / "infra/testnet"
    for name in ("Dockerfile.core", "Dockerfile.backend", "Dockerfile.backend-api"):
        shutil.copyfile(repo / "infra/docker" / name, root / "infra/infra/docker" / name)
    for path in (repo / "testnet").glob("docker-compose*.yml"):
        shutil.copyfile(path, target / path.name)
    for path in (repo / "testnet").glob("bootstrap.*.env"):
        shutil.copyfile(path, target / path.name)
    for name in ("Dockerfile.explorer", "services/faucet/Dockerfile",
                 "services/sdr-ingest/Dockerfile", "services/alert-receiver/Dockerfile", "edge/Dockerfile.caddy"):
        path = target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(repo / "testnet" / name, path)
    subprocess.run(["git", "-C", str(root / "infra"), "add", "."], check=True)
    subprocess.run(["git", "-C", str(root / "infra"), "-c", "user.name=Test", "-c",
                    "user.email=test@example.invalid", "commit", "-qm", "compose-fixture"], check=True)
    pins = dict(pins)
    pins["infra"] = subprocess.check_output(["git", "-C", str(root / "infra"), "rev-parse", "HEAD"], text=True).strip()
    files = [target / ("docker-compose." + name + ".yml") for name in
             ("testnet", "override", "edge", "funnel-edge", "container-health-watch")]
    text = "".join(p.read_text() for p in files)
    names = set(__import__("re").findall(r"\$\{([A-Z0-9_]+):\?", text))
    env = {k: v for k, v in os.environ.items() if k in {"PATH", "HOME"}}
    env.update({name: "synthetic" for name in names})
    env.update(WRFCOIN_ROOT=str(root), WRFCOIN_P2P_EXTERNAL_ADDR="/ip4/198.51.100.7/tcp/9000",
               WRFCOIN_SEED_P2P_EXTERNAL_ADDR="/ip4/203.0.113.9/tcp/9000")
    empty = root.parent / "synthetic.env"
    empty.write_text("")
    # No daemon: only the real Compose config parser, explicit empty env file.
    argv = ["docker", "compose", "--env-file", str(empty), "--profile", "seed", "--profile", "faucet",
            "--profile", "oracle-reference", "--profile", "container-health-watch"]
    for path in files: argv += ["-f", str(path)]
    initial = subprocess.run(argv + ["config", "--format", "json"], env=env, text=True, capture_output=True)
    assert initial.returncode == 0, initial.stderr
    render = json.loads(initial.stdout)
    result = run(render=render, pins=pins)
    assert result.returncode == 0, result.stderr
    overlay = root.parent / "revision-overlay.json"
    overlay.write_text(result.stdout)
    merged = subprocess.run(argv + ["-f", str(overlay), "config", "--format", "json"], env=env,
                            text=True, capture_output=True)
    assert merged.returncode == 0, merged.stderr
    updated = json.loads(merged.stdout)
    assert set(updated["services"]) == set(render["services"])
    expected_overlay = json.loads(result.stdout)["services"]
    assert len(expected_overlay) >= 17
    for name, before in render["services"].items():
        after = updated["services"][name]
        if name in expected_overlay:
            assert after["build"]["args"]["WRFCOIN_BUILD_REVISION"] == expected_overlay[name]["build"]["args"]["WRFCOIN_BUILD_REVISION"]
            assert after["build"]["labels"][LABEL] == expected_overlay[name]["build"]["labels"][LABEL]
            for key in ("args", "labels"):
                after["build"][key].pop("WRFCOIN_BUILD_REVISION" if key == "args" else LABEL)
                if before["build"].get(key, {}).get("WRFCOIN_BUILD_REVISION" if key == "args" else LABEL) is not None:
                    after["build"][key]["WRFCOIN_BUILD_REVISION" if key == "args" else LABEL] = before["build"][key]["WRFCOIN_BUILD_REVISION" if key == "args" else LABEL]
                if key not in before["build"]: after["build"].pop(key)
        assert after == before


@pytest.mark.parametrize("race", ["container", "inventory"])
def test_runtime_changed_metadata_never_passes(rig, race):
    root, _, _, _, run, _ = rig
    path = root.parent / "bin/docker"
    s = path.read_text()
    change = ("if d['reads']==1: next(iter(d['containers'].values()))['revision']='0'*40"
              if race == "container" else "if d['reads']==2: d['containers']['d'*64]=next(iter(d['containers'].values()))")
    replacement = ("if a[:2]==['container','inspect']:\n print(json.dumps(d['containers'][a[-1]]))\n"
                   " d['reads']=d.get('reads',0)+1\n " + change + "\n p.write_text(json.dumps(d))\n sys.exit()")
    s = s.replace("if a[:2]==['container','inspect']: print(json.dumps(d['containers'][a[-1]])); sys.exit()", replacement)
    path.write_text(s)
    result = run("check")
    assert result.returncode != 0 and not result.stdout
    assert result.stderr.strip() == "IMAGE_REVISIONS=STOP " + race + "-changed"


def test_non_object_metadata_refuses_without_traceback(rig):
    root, _, _, _, run, _ = rig
    path = root.parent / "bin/docker"
    s = path.read_text().replace("print(json.dumps(d['containers'][a[-1]]))", "print('[]')")
    path.write_text(s)
    result = run("check")
    assert result.returncode != 0 and not result.stdout
    assert result.stderr.strip() == "IMAGE_REVISIONS=STOP metadata-format"
