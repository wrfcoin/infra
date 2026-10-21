#!/usr/bin/env python3
"""Prepare exact-source build labels, or read only running Docker revision metadata."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

LABEL = "org.opencontainers.image.revision"
SHA = re.compile(r"[0-9a-f]{40}\Z")
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*\Z")
RECIPES = {
    "infra/infra/docker/Dockerfile.core": "core4",
    "infra/infra/docker/Dockerfile.backend": "backend",
    "infra/infra/docker/Dockerfile.backend-api": "backend",
        "infra/testnet/Dockerfile.frontend": "frontend",
    "infra/testnet/Dockerfile.explorer": "infra",
    # The real IPFS-only storage daemon is built from the storage-providers source (opt-in profile).
    "infra/infra/docker/Dockerfile.storage": "storage-providers",
}


class Refusal(Exception):
    pass


def require(condition, code):
    if not condition:
        raise Refusal(code)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate-json-key")
        result[key] = value
    return result


def read_json(path):
    require(Path(path).stat().st_size <= 8 * 1024 * 1024, "input-too-large")
    return json.loads(Path(path).read_text(), object_pairs_hook=unique)


def command(argv):
    # No stderr from Git/Docker: it can contain interpolated environment values.
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=15, env={k: v for k, v in os.environ.items()
                                            if k in {"PATH", "HOME", "XDG_RUNTIME_DIR"}})
    require(result.returncode == 0, "metadata-command-failed")
    require(len(result.stdout) <= 8 * 1024 * 1024, "metadata-too-large")
    return result.stdout.decode().strip()


def expected(root, pins, render, verify_source):
    require(isinstance(pins, dict) and pins, "pins-empty")
    require(all(isinstance(k, str) and NAME.fullmatch(k) and isinstance(v, str)
                and SHA.fullmatch(v) for k, v in pins.items()), "pin-format")
    services = render.get("services") if isinstance(render, dict) else None
    require(isinstance(services, dict) and services, "services-empty")
    repos = {name: root / name for name in pins}
    output, image_pins = {}, {}
    verified = set()
    for name, service in services.items():
        require(isinstance(name, str) and NAME.fullmatch(name) and isinstance(service, dict), "service-format")
        build = service.get("build")
        if build is None:
            continue
        require(isinstance(build, dict) and "dockerfile_inline" not in build, "build-format")
        context = build.get("context")
        require(isinstance(context, str) and Path(context).is_absolute(), "context-format")
        context = Path(context).resolve()
        recipe = (context / build.get("dockerfile", "Dockerfile")).resolve()
        require(recipe.is_file(), "recipe-missing")
        if context == root:
            relative = str(recipe.relative_to(root))
            require(relative in RECIPES, "workspace-recipe-unmapped")
            source = RECIPES[relative]
        else:
            matches = [repo for repo, path in repos.items()
                       if context.is_relative_to(path) and recipe.is_relative_to(path)]
            require(len(matches) == 1, "context-unmapped")
            source = matches[0]
            # Workspace COPY recipes cannot be relabelled as infra-only builds.
            require(str(recipe.relative_to(root)) not in RECIPES
                    or RECIPES[str(recipe.relative_to(root))] == source, "recipe-context-disagreement")
        require(source in pins, "source-pin-missing")
        recipe_owners = [repo for repo, path in repos.items() if recipe.is_relative_to(path)]
        require(len(recipe_owners) == 1, "recipe-owner-unmapped")
        if verify_source:
            for owner in {source, recipe_owners[0]} - verified:
                repo = repos[owner]
                require(command(["git", "-C", str(repo), "rev-parse", "--show-toplevel"]) == str(repo), "source-root")
                require(command(["git", "-C", str(repo), "rev-parse", "HEAD"]) == pins[owner], "source-head")
                require(not command(["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=normal"]), "source-dirty")
                verified.add(owner)
        pin = pins[source]
        output[name] = pin
        image = service.get("image")
        if image:
            require(isinstance(image, str), "image-format")
            require(image not in image_pins or image_pins[image] == pin, "image-pin-collision")
            image_pins[image] = pin
    require(output, "no-builds")
    for name, service in services.items():
        if service.get("image") in image_pins:
            output[name] = image_pins[service["image"]]
    return output, {name for name, s in services.items() if s.get("build") is not None}


CONTAINER_FORMAT = ('{"id":{{json .Id}},"image":{{json .Image}},"running":{{json .State.Running}},'
                    '"project":{{json (index .Config.Labels "com.docker.compose.project")}},'
                    '"service":{{json (index .Config.Labels "com.docker.compose.service")}},'
                    '"revision":{{json (index .Config.Labels "org.opencontainers.image.revision")}}}')
IMAGE_FORMAT = ('{"id":{{json .Id}},'
                '"revision":{{json (index .Config.Labels "org.opencontainers.image.revision")}}}')


def inspect(kind, identity, template):
    value = json.loads(command(["docker", kind, "inspect", "--format", template, identity]), object_pairs_hook=unique)
    require(isinstance(value, dict), "metadata-format")
    return value


def check(revisions, services, project, required):
    require(NAME.fullmatch(project) and required and set(required) <= set(revisions), "required-service-format")
    ids = command(["docker", "ps", "--filter", "label=com.docker.compose.project=" + project,
                   "--quiet", "--no-trunc"]).splitlines()
    require(ids and len(ids) <= 256 and len(ids) == len(set(ids)), "running-inventory")
    require(all(re.fullmatch("[0-9a-f]{64}", cid) for cid in ids), "container-id-format")
    checked = set()
    for cid in ids:
        container = inspect("container", cid, CONTAINER_FORMAT)
        require(container.get("id") == cid and container.get("project") == project
                and container.get("running") is True, "container-membership")
        name = container.get("service")
        require(name in services, "service-unmapped")
        if name not in revisions:
            # Pulled third-party images are outside our source-build stamp.
            require(not services[name].get("build") and not services[name].get("image", "").startswith("wrfcoin/"),
                    "local-image-unmapped")
            continue
        image = container.get("image")
        require(isinstance(image, str) and re.fullmatch("sha256:[0-9a-f]{64}", image), "image-id-format")
        metadata = inspect("image", image, IMAGE_FORMAT)
        pin = revisions[name]
        require(metadata.get("id") == image and metadata.get("revision") == pin
                and container.get("revision") == pin, "revision-disagreement")
        require(inspect("container", cid, CONTAINER_FORMAT) == container, "container-changed")
        checked.add(name)
    require(set(required) <= checked, "required-service-absent")
    # A second inventory prevents a disappearing/replaced container receiving PASS.
    require(command(["docker", "ps", "--filter", "label=com.docker.compose.project=" + project,
                     "--quiet", "--no-trunc"]).splitlines() == ids, "inventory-changed")
    return {"status": "PASS", "evidence_class": "RUNNING-IMAGE-REVISION-ONLY", "checked": sorted(checked)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "check"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--pins", type=Path, required=True)
    parser.add_argument("--render", type=Path, required=True)
    parser.add_argument("--project")
    parser.add_argument("--require", action="append", default=[])
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        pins, render = read_json(args.pins), read_json(args.render)
        revisions, builds = expected(root, pins, render, args.mode == "prepare")
        if args.mode == "prepare":
            result = {"services": {name: {"build": {"args": {"WRFCOIN_BUILD_REVISION": revisions[name]},
                                                   "labels": {LABEL: revisions[name]}}} for name in sorted(builds)}}
        else:
            result = check(revisions, render["services"], args.project or "", args.require)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (Refusal, OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        # Fixed error classes only; raw config, Docker stderr and credentials stay private.
        code = str(exc) if isinstance(exc, Refusal) else type(exc).__name__
        print("IMAGE_REVISIONS=STOP " + code, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
