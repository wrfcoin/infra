"""Offline selected-source fixture report. Never accepts a host env or runtime target."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import yaml

PIN = "1"*64
GENESIS = "2"*64
IMAGE = "fixture/native:owner-exact"
FILES = ["docker-compose.testnet.yml", "docker-compose.override.yml", "docker-compose.local-paths.yml",
         "bootstrap.777.env", "bootstrap.888.env",
         "docker-compose.yubikey.n5.yml", "docker-compose.oracle-attester.yml",
         "docker-compose.oracle-attester-yubikey.n5.yml", "docker-compose.container-health-watch.yml",
         "boot-heal.sh", "lib/compose-inputs.sh", "scripts/render-cut-overlay.sh"]
class Refused(ValueError):
    pass

def run(args, cwd, env):
    r=subprocess.run(args,cwd=cwd,env=env,capture_output=True,text=True,timeout=30)
    if r.returncode:
        # Do not emit rendered environment values or subprocess diagnostics.
        raise Refused("offline custody command refused: " + str(args[0]))
    return r.stdout

def fixture(root, tmp, *, profiles="", seed=True, trust=PIN, change=None):
    root, tmp=Path(root),Path(tmp)
    t=tmp/"testnet";t.mkdir()
    for name in FILES:
        source=root/"testnet"/name
        if source.exists():
            out=t/name;out.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,out)
    (tmp/"scripts").mkdir();shutil.copyfile(root/"scripts/cut-overlay-custody.py",tmp/"scripts/cut-overlay-custody.py")
    # Required Compose placeholders get synthetic strings, never owner values.
    text="\n".join(p.read_text()for p in t.rglob("*.yml"))
    keys=set(re.findall(r"\$\{([A-Z0-9_]+):\?",text))
    # DOCKER_HOST / DOCKER_CONFIG are deliberately NOT passed through: the report is daemonless and must not
    # be steered to a host daemon or a host credential/context store by the caller's shell (Refs #1257).
    env={k:os.environ[k] for k in ("PATH","HOME","TMPDIR","SOL_N_DENIED_LOG") if k in os.environ}
    env.update({k:"synthetic-fixture-only"for k in keys})
    env.update(COMPOSE_PROFILES=profiles,WRFCOIN_HSM_MODE="yubikey")
    (t/".env").write_text("# synthetic empty env; no owner credential file\n")
    pins=t/"cut-pins.env"
    pins.write_text("WRFCOIN_CUT_GENESIS_HASH="+GENESIS+"\nWRFCOIN_CUT_INCLUDE_SEED="+str(int(seed))+"\nWRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS="+trust+"\n")
    run(["bash",str(t/"scripts/render-cut-overlay.sh"),"--pins",str(pins),"--out",str(t/"docker-compose.cut.yml")],t,env)
    (t/"docker-compose.cut-genesis-seed.yml").write_text(yaml.safe_dump({"services":{"wrfcoin-seed":{"environment":{"WRFCOIN_GENESIS_HASH":GENESIS}}}}))
    custody=t/"synthetic-hsm-custody.conf"
    rows=["HSM_INIT_IMAGE_IDS=sha256:"+"a"*64]
    for owner in ("NODE","SEED"):
        rows.append("HSM_INIT_"+owner+"_VOLUME_MOUNTPOINT=/synthetic/"+owner.lower())
        for field in ("CMD","ENTRYPOINT","HEALTHCHECK","PUBLIC_KEY"):
            rows.append("HSM_INIT_"+owner+"_"+field+"_SHA256="+"a"*64)
    custody.write_text("\n".join(rows)+"\n")
    owner=tmp/"synthetic-owner.yml"
    image_services=("wrfcoin-node","wrfcoin-seed","softhsm-init","softhsm-seed-init","oracle-attester")
    body={"services":{s:{"image":IMAGE}for s in image_services}}
    if change=="conflicting-override":
        body["services"]["wrfcoin-node"]["environment"]={"WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS":"3"*64}
    if change=="reset-restore":
        # SOL-R's valid tagged input: the authored override resets wrfcoin-node, and the owner overlay restores it.
        body["services"]["wrfcoin-node"]["environment"]={"WRFCOIN_GENESIS_HASH":GENESIS,"WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS":trust}
        ov=t/"docker-compose.override.yml"
        lines=ov.read_text().splitlines(keepends=True)
        start=lines.index("  wrfcoin-node:\n")
        end=next(i for i in range(start+1,len(lines))if lines[i].strip()and not lines[i].startswith("   ")and not lines[i].lstrip().startswith("#"))
        ov.write_text("".join(lines[:start]+["  wrfcoin-node: !reset {}\n"]+lines[end:]))
    if change=="identical-override":
        # Same value as the reviewed pin: the merged render stays valid, but the winning SOURCE changes.
        body["services"]["wrfcoin-node"]["environment"]={"WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS":trust}
    owner.write_text(yaml.safe_dump(body))
    env.update(WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE=str(owner),WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG=str(custody))
    if change=="missing-hsm-custody": custody.unlink()
    if change=="missing-cut-custody": Path(str(t/"docker-compose.cut.yml")+".custody.json").unlink()
    if change=="missing-attester-companion": (t/"docker-compose.oracle-attester-yubikey.n5.yml").unlink()
    if change in ("attester-data-bind","attester-cap-drop"):
        path=t/"docker-compose.oracle-attester.yml"
        text=path.read_text();before,role=text.split("  oracle-attester:\n",1)
        old,new=("      - oracle-attester-data:/app/data", "      - /synthetic/attester-data:/app/data") if change=="attester-data-bind" else ("    cap_drop:\n      - ALL\n", "")
        assert old in role;path.write_text(before+"  oracle-attester:\n"+role.replace(old,new))
    elif change and change.startswith("attester-"):
        path=t/"docker-compose.oracle-attester-yubikey.n5.yml"
        text=path.read_text()
        removals={
            "attester-socket": ("      - /run/pcscd:/run/pcscd:ro\n", ""),
            "attester-user": ("    user: root\n", ""),
            "attester-privilege": ("    security_opt: !reset []\n", ""),
            "attester-capabilities": ("    cap_add:\n      - SETUID\n      - SETGID\n", ""),
            "attester-module": ("libykcs11.so", "libsofthsm2.so"),
            "attester-socket-rw": ("/run/pcscd:/run/pcscd:ro", "/run/pcscd:/run/pcscd:rw"),
            "attester-raw-devices": ("    user: root\n", "    user: root\n    devices:\n      - /dev/bus/usb:/dev/bus/usb\n"),
            "attester-extra-mount": ("      - /run/pcscd:/run/pcscd:ro\n", "      - /run/pcscd:/run/pcscd:ro\n      - /synthetic/extra:/extra:ro\n"),
            "attester-socket-volume": ("      - /run/pcscd:/run/pcscd:ro\n", "      - fixture-pcscd:/run/pcscd:ro\n\nvolumes:\n  fixture-pcscd: {}\n"),
            "attester-socket-source": ("/run/pcscd:/run/pcscd:ro", "/synthetic/socket:/run/pcscd:ro"),
        }
        old,new=removals[change];assert old in text;path.write_text(text.replace(old,new))
    return t,env,image_services

class Tagged:
    """A Compose merge tag (`!reset` / `!override`) kept with the value it wraps."""
    def __init__(self,tag,value):
        self.tag,self.value=tag,value

class _ComposeLoader(yaml.SafeLoader):
    """SafeLoader that keeps Compose merge tags instead of erasing them."""

def _compose_tag(loader,suffix,node):
    if isinstance(node,yaml.MappingNode):value=loader.construct_mapping(node,deep=True)
    elif isinstance(node,yaml.SequenceNode):value=loader.construct_sequence(node,deep=True)
    else:value=loader.construct_scalar(node)
    return Tagged(suffix,value)

_ComposeLoader.add_multi_constructor("!",_compose_tag)

def _env_items(env):
    """Normalise an `environment` value (mapping or `K=V` list) to a dict of key -> value-or-Tagged."""
    if isinstance(env,list):
        return dict(item.split("=",1)if"="in item else(item,None)for item in env)
    return dict(env)if isinstance(env,dict)else{}

def source_winner(compose_dir,files,role,key):
    """(file name, value) of the input that sets `key` for `role` after Compose merge semantics, else (None, None).

    Mirrors how `docker compose` merges the selected files, for this one key:
    - `environment` merges per key and later files win;
    - `!reset` on the key, on `environment`, on the service or on `services` clears it;
    - `!override` on `environment`, the service or `services` replaces what earlier files set, so a key the
      replacement omits is cleared;
    - a later file may restore what an earlier one cleared.
    The result is read from the input files only (no daemon), and the report separately requires it to equal
    the merged render.
    """
    winner,value=None,None
    def clear():
        nonlocal winner,value
        winner,value=None,None
    for f in files:
        data=yaml.load((Path(compose_dir)/f).read_text(),Loader=_ComposeLoader) or {}
        services=data.get("services")if isinstance(data,dict)else None
        if isinstance(services,Tagged):
            clear()
            if services.tag=="reset":continue
            services=services.value
        if not isinstance(services,dict)or role not in services:continue
        svc=services[role]
        if isinstance(svc,Tagged):
            clear()
            if svc.tag=="reset":continue
            svc=svc.value
        if not isinstance(svc,dict)or"environment"not in svc:continue
        env=svc["environment"]
        if isinstance(env,Tagged):
            clear()
            if env.tag=="reset":continue
            env=env.value
        items=_env_items(env)
        if key in items:
            entry=items[key]
            if isinstance(entry,Tagged)and entry.tag=="reset":clear()
            else:winner,value=Path(f).name,(entry.value if isinstance(entry,Tagged)else entry)
    return winner,value

def report(root,tmp,**settings):
    t,env,image_services=fixture(root,tmp,**settings)
    # The shipped boot code admits HSM custody and companion files before this
    # daemonless render. This report additionally admits canonical cut custody.
    files=run(["bash",str(t/"boot-heal.sh"),"--print-compose-files"],t,env).splitlines()
    run(["bash",str(t/"scripts/render-cut-overlay.sh"),"--pins",str(t/"cut-pins.env"),"--out",str(t/"docker-compose.cut.yml"),"--check"],t,env)
    args=["docker","compose"]
    for f in files:args += ["-f",f]
    for p in settings.get("profiles","").replace(","," ").split():args += ["--profile",p]
    services=json.loads(run(args+["--profile","*","config","--format","json"],t,env))["services"]
    active=set(run(args+["config","--services"],t,env).splitlines())
    active_boot=set(run(["bash",str(t/"boot-heal.sh"),"--print-reconcile-services"],t,env).splitlines())
    rows=[]
    for role in ("wrfcoin-node","wrfcoin-seed"):
        if role not in active:continue
        values=services[role]["environment"]
        if values.get("WRFCOIN_GENESIS_HASH")!=GENESIS or values.get("WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS")!=settings.get("trust",PIN):
            raise Refused("effective cut/trust conflict")
        genesis_winner,genesis_value=source_winner(t,files,role,"WRFCOIN_GENESIS_HASH")
        trust_winner,trust_value=source_winner(t,files,role,"WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS")
        # The merged render and the winning source must agree; otherwise the label would describe a different file.
        if genesis_value!=GENESIS or trust_value!=settings.get("trust",PIN) or genesis_winner is None or trust_winner is None:
            raise Refused("effective winner derivation disagrees with the merged render")
        if genesis_winner=="docker-compose.cut-genesis-seed.yml":
            genesis_winner+=" (synthetic retained seed companion)"
        rows.append(dict(role=role,field="genesis_and_snapshot_trust",genesis_winner=genesis_winner,trust_winner=trust_winner,matches_reviewed_pins=True))
    for role in image_services:
        if services[role]["image"]!=IMAGE:raise Refused("owner image precedence")
        rows.append(dict(role=role,field="image",winner="synthetic-owner.yml",value=IMAGE,active=role in active))
    if "oracle-attester" in active:
        a=services["oracle-attester"]
        mounts={m["target"]:m for m in a.get("volumes",[])}
        socket=mounts.get("/run/pcscd",{})
        if (a.get("profiles")!=["attester"] or a.get("user")!="root"
                or a.get("security_opt",[])!=[] or set(a.get("cap_add",[]))!={"SETUID","SETGID"}
                or a.get("cap_drop")!=["ALL"] or a.get("devices")
                or a.get("environment",{}).get("WRFCOIN_HSM_MODULE_PATH")!="/usr/lib/x86_64-linux-gnu/libykcs11.so"
                or set(mounts)!={"/app/data","/run/pcscd"}
                or mounts.get("/app/data",{}).get("type")!="volume"
                or socket.get("type")!="bind" or socket.get("source")!="/run/pcscd" or socket.get("read_only") is not True):
            raise Refused("attester custody shape")
    return dict(evidence_class="synthetic selected-source daemonless Compose; no runtime custody",
                input_order=[Path(f).name for f in files],
                hsm_custody="synthetic-hsm-custody.conf admitted by boot-heal",
                cut_custody="docker-compose.cut.yml.custody.json admitted by canonical checker",
                health_watch_active="container-health-watch"in active_boot,
                health_watch_winner="COMPOSE_PROFILES explicit synthetic environment",
                effective=rows,
                source_sha256={name:hashlib.sha256((Path(root)/"testnet"/name).read_bytes()).hexdigest()for name in [*FILES,"../scripts/cut-overlay-custody.py"] if(Path(root)/"testnet"/name).is_file()})
