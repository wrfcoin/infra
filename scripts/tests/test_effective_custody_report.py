"""Actual selected-source/helper/Compose boundaries with synthetic inputs only."""
import json
import os
import hashlib
import shutil
from pathlib import Path
import pytest
from effective_custody_fixture import report, Refused, PIN
ROOT=Path(__file__).resolve().parents[2]

@pytest.mark.parametrize("profiles",["", "seed", "seed,attester", "container-health-watch", "seed,attester,container-health-watch"])
def test_selected_sources_and_owner_precedence(tmp_path,profiles):
    r=report(ROOT,tmp_path,profiles=profiles)
    assert r["input_order"][-1]=="synthetic-owner.yml"
    assert r["input_order"].index("docker-compose.cut.yml") < r["input_order"].index("synthetic-owner.yml")
    assert r["health_watch_active"]==("container-health-watch"in profiles)
    images=[x for x in r["effective"]if x["field"]=="image"]
    assert len(images)==5 and all(x["winner"]=="synthetic-owner.yml"for x in images)
    roles=[x["role"]for x in r["effective"]if x["field"]=="genesis_and_snapshot_trust"]
    assert roles==(["wrfcoin-node","wrfcoin-seed"]if "seed"in profiles else["wrfcoin-node"])
    assert r["source_sha256"]["../scripts/cut-overlay-custody.py"]==hashlib.sha256((ROOT/"scripts/cut-overlay-custody.py").read_bytes()).hexdigest()
    assert "synthetic-fixture-only"not in json.dumps(r)
    if os.environ.get("SOL_N_REPORT_DIR"):
        out=Path(os.environ["SOL_N_REPORT_DIR"]);out.mkdir(exist_ok=True)
        (out/("report-"+(profiles.replace(",","-") or "default")+".json")).write_text(json.dumps(r,sort_keys=True,indent=2)+"\n")

@pytest.mark.parametrize("change",["missing-hsm-custody","missing-cut-custody","missing-attester-companion","conflicting-override"])
def test_missing_or_conflicting_custody_refuses_report(tmp_path,change):
    with pytest.raises(Refused):report(ROOT,tmp_path,profiles="seed,attester",change=change)

@pytest.mark.parametrize("trust",[""])
def test_seed_without_pin_refuses_before_compose(tmp_path,trust):
    with pytest.raises(Refused):report(ROOT,tmp_path,profiles="seed",seed=True,trust=trust)

@pytest.mark.parametrize("change",["attester-socket","attester-user","attester-privilege","attester-capabilities","attester-module"])
def test_present_but_damaged_yubikey_companion_refuses(tmp_path,change):
    with pytest.raises(Refused):report(ROOT,tmp_path,profiles="seed,attester",change=change)


def test_changed_checker_that_still_accepts_has_distinct_provenance(tmp_path):
    from effective_custody_fixture import FILES
    one=tmp_path/"one";one.mkdir();r1=report(ROOT,one)
    changed=tmp_path/"source";changed.mkdir()
    for name in FILES:
        src=ROOT/"testnet"/name
        if src.is_file():
            dst=changed/"testnet"/name;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dst)
    checker=changed/"scripts/cut-overlay-custody.py";checker.parent.mkdir();checker.write_bytes((ROOT/"scripts/cut-overlay-custody.py").read_bytes()+b"\n# synthetic accepting verifier generation\n")
    two=tmp_path/"two";two.mkdir();r2=report(changed,two)
    assert r1["source_sha256"]["../scripts/cut-overlay-custody.py"]!=r2["source_sha256"]["../scripts/cut-overlay-custody.py"]
    assert r1["effective"]==r2["effective"]


@pytest.mark.parametrize("change",["attester-socket-rw","attester-raw-devices","attester-extra-mount","attester-data-bind","attester-cap-drop","attester-socket-volume","attester-socket-source"])
def test_transport_safety_clauses_refuse_damaged_authored_inputs(tmp_path,change):
    with pytest.raises(Refused,match="attester custody shape"):
        report(ROOT,tmp_path,profiles="seed,attester",change=change)


def test_malformed_rendered_socket_type_refuses_independently(tmp_path,monkeypatch):
    # Actual Compose volume sources cannot be an absolute bind path. An authored
    # volume control therefore exercises source and type together. Independently
    # corrupt just the parsed boundary type after the real render, preserving the
    # source and read-only flag, to pin the explicit type defense as well.
    import effective_custody_fixture as fixture
    real_run=fixture.run
    def damaged_render(args,cwd,env):
        text=real_run(args,cwd,env)
        if args[0]=="docker" and "--format" in args:
            parsed=json.loads(text)
            mounts=parsed["services"]["oracle-attester"]["volumes"]
            next(m for m in mounts if m["target"]=="/run/pcscd")["type"]="volume"
            return json.dumps(parsed)
        return text
    monkeypatch.setattr(fixture,"run",damaged_render)
    with pytest.raises(Refused,match="attester custody shape"):
        report(ROOT,tmp_path,profiles="seed,attester")

def test_identical_value_override_changes_the_reported_winner(tmp_path):
    """A later overlay that sets the SAME trust value keeps the render valid but must not be labelled cut.yml."""
    a,b=tmp_path/"a",tmp_path/"b"
    a.mkdir();b.mkdir()
    base=report(ROOT,a,profiles="")
    same=report(ROOT,b,profiles="",change="identical-override")
    node=lambda r:[x for x in r["effective"]if x["field"]=="genesis_and_snapshot_trust"and x["role"]=="wrfcoin-node"][0]
    assert node(base)["trust_winner"]=="docker-compose.cut.yml"
    assert node(same)["trust_winner"]=="synthetic-owner.yml"
    # Genesis was not touched by that overlay, so its winner is unchanged.
    assert node(same)["genesis_winner"]==node(base)["genesis_winner"]


def test_conflicting_value_still_refuses_not_mislabels(tmp_path):
    with pytest.raises(Refused):report(ROOT,tmp_path,profiles="",change="conflicting-override")


def test_docker_host_and_config_are_not_passed_to_the_fixture(tmp_path,monkeypatch):
    from effective_custody_fixture import fixture
    monkeypatch.setenv("DOCKER_HOST","tcp://127.0.0.1:1")
    monkeypatch.setenv("DOCKER_CONFIG",str(tmp_path/"host-docker-config"))
    t,env,_=fixture(ROOT,tmp_path)
    assert "DOCKER_HOST"not in env and "DOCKER_CONFIG"not in env
    assert "tcp://127.0.0.1:1"not in json.dumps(env)
    # The daemonless report still works with those variables set in the caller's shell.
    out=tmp_path/"r";out.mkdir()
    assert report(ROOT,out)["effective"]


# --- Compose tag provenance (Refs #1257): derivation must equal what `docker compose config` renders -------------
import subprocess
from effective_custody_fixture import source_winner

KEY="WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS"
ROLE="wrfcoin-node"
SET_A="services:\n  wrfcoin-node:\n    image: x\n    environment:\n      WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: aaa\n      OTHER: keep\n"
TAGGED_CASES={
    "later-sets-same-value":([SET_A,"services:\n  wrfcoin-node:\n    environment:\n      WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: aaa\n"],"b.yml","aaa"),
    "later-sets-new-value":([SET_A,"services:\n  wrfcoin-node:\n    environment:\n      WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: bbb\n"],"b.yml","bbb"),
    "later-list-form-sets":([SET_A,"services:\n  wrfcoin-node:\n    environment:\n      - WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=ccc\n"],"b.yml","ccc"),
    "later-merges-other-key-only":([SET_A,"services:\n  wrfcoin-node:\n    environment:\n      OTHER: changed\n"],"a.yml","aaa"),
    "environment-override-omits-key":([SET_A,"services:\n  wrfcoin-node:\n    environment: !override\n      OTHER: synthetic\n"],None,None),
    "environment-override-keeps-key":([SET_A,"services:\n  wrfcoin-node:\n    environment: !override\n      WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: ddd\n"],"b.yml","ddd"),
    "environment-reset":([SET_A,"services:\n  wrfcoin-node:\n    environment: !reset {}\n"],None,None),
    "key-reset":([SET_A,"services:\n  wrfcoin-node:\n    environment:\n      WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: !reset null\n"],None,None),
    "service-override-omits-environment":([SET_A,"services:\n  wrfcoin-node: !override\n    image: y\n"],None,None),
    "service-reset-then-restore":([SET_A,"services:\n  wrfcoin-node: !reset {}\n","services:\n  wrfcoin-node:\n    image: z\n    environment:\n      WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: eee\n"],"c.yml","eee"),
    "services-reset-then-restore":([SET_A,"services: !reset {}\n","services:\n  wrfcoin-node:\n    image: z\n    environment:\n      WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: fff\n"],"c.yml","fff"),
    "restore-after-key-reset":([SET_A,"services:\n  wrfcoin-node:\n    environment:\n      WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: !reset null\n","services:\n  wrfcoin-node:\n    environment:\n      WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: ggg\n"],"c.yml","ggg"),
}

@pytest.mark.parametrize("case",sorted(TAGGED_CASES))
def test_winner_derivation_equals_actual_compose(tmp_path,case):
    texts,want_file,want_value=TAGGED_CASES[case]
    names=[]
    for i,text in enumerate(texts):
        name="abcdefgh"[i]+".yml";(tmp_path/name).write_text(text);names.append(name)
    args=["docker","compose"]
    for n in names:args+=["-f",n]
    out=subprocess.run(args+["config","--format","json"],cwd=tmp_path,env={k:os.environ[k]for k in("PATH","HOME")if k in os.environ},capture_output=True,text=True,timeout=60)
    assert out.returncode==0,out.stderr[-300:]
    compose=json.loads(out.stdout)["services"].get(ROLE,{}).get("environment",{}).get(KEY)
    winner,value=source_winner(tmp_path,names,ROLE,KEY)
    assert value==compose, "derived value must equal what Compose renders"
    assert (winner,value)==(want_file,want_value)


def test_reset_then_restore_reports_the_restoring_file_through_report(tmp_path):
    """SOL-R's reproduction: the authored override resets wrfcoin-node; the owner overlay restores both pins."""
    r=report(ROOT,tmp_path,profiles="",change="reset-restore")
    node=[x for x in r["effective"]if x["field"]=="genesis_and_snapshot_trust"and x["role"]=="wrfcoin-node"][0]
    assert node["genesis_winner"]=="synthetic-owner.yml" and node["trust_winner"]=="synthetic-owner.yml"
