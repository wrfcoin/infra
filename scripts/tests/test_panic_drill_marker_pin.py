"""Controls for scripts/check_panic_drill_marker_pin.py (infra#1034 N1). Hermetic fake core4 trees."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location(
    "check_panic_drill_marker_pin", ROOT / "scripts/check_panic_drill_marker_pin.py"
)
pin = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = pin
_spec.loader.exec_module(pin)

MARKER = "WRFCOIN_PANIC_DRILL_P2P_CONSUMER_TRIGGER"
CHECKER = f'PANIC_DRILL_FEATURE = "panic-drill"\nPANIC_DRILL_MARKER = "{MARKER}"\n'


def _core4(tmp_path: Path, *, declared: bool, source: str) -> Path:
    core4 = tmp_path / "core4"
    main_rs = core4 / "native-chain/src/bin/launch_api/main.rs"
    main_rs.parent.mkdir(parents=True)
    main_rs.write_text(source, encoding="utf-8")
    features = "[features]\np2p = []\n" + ('panic-drill = ["p2p"]\n' if declared else "")
    (core4 / "native-chain/Cargo.toml").write_text(features, encoding="utf-8")
    return core4


def _checker(tmp_path: Path, text: str = CHECKER) -> Path:
    path = tmp_path / "check_release_endpoints.py"
    path.write_text(text, encoding="utf-8")
    return path


def _run(core4: Path, checker: Path) -> int:
    return pin.main(["--core4", str(core4), "--checker", str(checker)])


# The trigger const must be read somewhere in live code, or it is a dead const (infra#1038 R1).
USE = "fn drill() { let _ = std::env::var_os(PANIC_DRILL_ENV); }\n"


def test_declared_and_marker_present_is_live(tmp_path, capsys):
    core4 = _core4(tmp_path, declared=True, source=f'const PANIC_DRILL_ENV: &str = "{MARKER}";\n' + USE)
    assert _run(core4, _checker(tmp_path)) == 0
    assert "binary scan is live" in capsys.readouterr().out


def test_neither_is_vacuous_but_passes(tmp_path, capsys):
    core4 = _core4(tmp_path, declared=False, source="fn main() {}\n")
    assert _run(core4, _checker(tmp_path)) == 0
    assert "VACUOUS" in capsys.readouterr().out


def test_marker_renamed_fails(tmp_path, capsys):
    core4 = _core4(tmp_path, declared=True,
                   source='const PANIC_DRILL_ENV: &str = "WRFCOIN_P2P_PANIC_DRILL_TRIGGER";\n')
    assert _run(core4, _checker(tmp_path)) == 1
    assert "marker was renamed" in capsys.readouterr().err


def test_feature_renamed_fails(tmp_path, capsys):
    core4 = _core4(tmp_path, declared=False, source=f'const PANIC_DRILL_ENV: &str = "{MARKER}";\n')
    (core4 / "native-chain/Cargo.toml").write_text('[features]\np2p-panic-drill = ["p2p"]\n', encoding="utf-8")
    assert _run(core4, _checker(tmp_path)) == 1
    assert "feature was renamed" in capsys.readouterr().err


@pytest.mark.parametrize("text", ['PANIC_DRILL_FEATURE = "panic-drill"\n', "X = 1\n", "def (:\n"])
def test_checker_without_pin_fails_closed(tmp_path, text):
    core4 = _core4(tmp_path, declared=True, source=f'"{MARKER}"\n')
    assert _run(core4, _checker(tmp_path, text)) == 1


def test_not_a_core4_checkout_fails(tmp_path):
    assert _run(tmp_path / "empty", _checker(tmp_path)) == 1


# --- B1 (review of #1037): the marker only counts as a live, non-test string literal ---------

def _declared(tmp_path: Path, source: str) -> int:
    return _run(_core4(tmp_path, declared=True, source=source), _checker(tmp_path))


RENAMED = 'const PANIC_DRILL_ENV: &str = "WRFCOIN_P2P_DRILL_RENAMED";\n'


@pytest.mark.parametrize(
    "source",
    [
        # comment-only survivors of a rename
        RENAMED + f"// formerly {MARKER}\n",
        RENAMED + f"/// Trigger env var (was `{MARKER}`).\n",
        RENAMED + f"/* formerly \"{MARKER}\" */\n",
        RENAMED + f"/* outer /* nested */ \"{MARKER}\" still comment */\n",
        # test-only survivors
        RENAMED + f'#[cfg(test)]\nmod tests {{\n    const OLD: &str = "{MARKER}";\n}}\n',
        RENAMED + f'#[cfg(all(test, feature = "p2p"))]\nfn helper() {{ let _ = "{MARKER}"; }}\n',
        RENAMED + f'#[cfg(test)]\nconst OLD: &str = "{MARKER}";\n',
        # substring inside a message is not the trigger literal
        RENAMED + f'const HELP: &str = "set {MARKER} to a file";\n',
    ],
    ids=["line-comment", "doc-comment", "block-comment", "nested-block-comment",
         "cfg-test-mod", "cfg-all-test-fn", "cfg-test-const", "substring-in-message"],
)
def test_marker_outside_live_string_literal_is_blind(tmp_path, source, capsys):
    assert _declared(tmp_path, source) == 1
    assert "marker was renamed" in capsys.readouterr().err


def test_marker_only_in_tests_file_is_blind(tmp_path):
    core4 = _core4(tmp_path, declared=True, source=RENAMED)
    extra = core4 / "native-chain/src/p2p/tests.rs"
    extra.parent.mkdir(parents=True)
    extra.write_text(f'const OLD: &str = "{MARKER}";\n', encoding="utf-8")
    assert _run(core4, _checker(tmp_path)) == 1


@pytest.mark.parametrize(
    "source",
    [
        f'const PANIC_DRILL_ENV: &str = r#"{MARKER}"#;\n',
        f'const PANIC_DRILL_ENV: &str = r"{MARKER}";\n',
        # comment-like text inside strings must not swallow the real literal
        f'const URL: &str = "http://x/*";\nconst PANIC_DRILL_ENV: &str = "{MARKER}";\n',
        f'const Q: char = \'"\';\nconst PANIC_DRILL_ENV: &str = "{MARKER}";\n',
        f'fn f<\'a>(x: &\'a str) -> &\'a str {{ x }}\nconst PANIC_DRILL_ENV: &str = "{MARKER}";\n',
        f'const RAW: &str = r#"quote " and // not a comment"#;\nconst PANIC_DRILL_ENV: &str = "{MARKER}";\n',
        # a non-test cfg (the real shape) and cfg(not(test)) stay live
        f'#[cfg(all(feature = "p2p", feature = "panic-drill"))]\nconst PANIC_DRILL_ENV: &str = "{MARKER}";\n',
        f'#[cfg(not(test))]\nconst PANIC_DRILL_ENV: &str = "{MARKER}";\n',
        # a test module BEFORE the real literal must not hide it
        f'#[cfg(test)]\nmod tests {{ fn t() {{ let _ = "}}"; }} }}\nconst PANIC_DRILL_ENV: &str = "{MARKER}";\n',
    ],
    ids=["raw-hash", "raw-plain", "url-in-string", "quote-char", "lifetimes", "raw-with-quote",
         "feature-cfg", "cfg-not-test", "test-mod-before"],
)
def test_live_literal_variants_are_found(tmp_path, source, capsys):
    assert _declared(tmp_path, source + USE) == 0, capsys.readouterr().err


# --- infra#1038 R1: a dead const that carries the old marker must not count as live ----------

def test_dead_const_with_old_marker_is_blind(tmp_path, capsys):
    # The reproduction from the issue: the real trigger was renamed and an unused const keeps the old marker.
    source = (RENAMED + "fn drill() { let _ = std::env::var_os(PANIC_DRILL_ENV); }\n"
              + f'pub const OLD: &str = "{MARKER}";\n')
    assert _declared(tmp_path, source) == 1
    err = capsys.readouterr().err
    assert "trigger is dead" in err and "OLD" not in err.split("ERROR")[0]


def test_dead_static_with_old_marker_is_blind(tmp_path):
    assert _declared(tmp_path, RENAMED + f'pub static OLD: &str = "{MARKER}";\n') == 1


def test_const_referenced_from_another_file_is_live(tmp_path):
    core4 = _core4(tmp_path, declared=True, source=f'pub const PANIC_DRILL_ENV: &str = "{MARKER}";\n')
    other = core4 / "native-chain/src/drill.rs"
    other.write_text("fn go() { let _ = crate::PANIC_DRILL_ENV; }\n", encoding="utf-8")
    assert _run(core4, _checker(tmp_path)) == 0


@pytest.mark.parametrize(
    "use",
    [
        "// let _ = PANIC_DRILL_ENV;\n",
        "#[cfg(test)]\nmod tests { fn t() { let _ = super::PANIC_DRILL_ENV; } }\n",
        'const NOTE: &str = "PANIC_DRILL_ENV";\n',
    ],
    ids=["comment", "cfg-test-reference", "name-inside-string"],
)
def test_const_referenced_only_outside_live_code_is_blind(tmp_path, use):
    assert _declared(tmp_path, f'const PANIC_DRILL_ENV: &str = "{MARKER}";\n' + use) == 1


def test_mut_static_and_typed_const_are_tracked(tmp_path):
    live = f'static mut PANIC_DRILL_ENV: &\'static str = "{MARKER}";\n' + USE
    assert _declared(tmp_path, live) == 0


def test_dead_const_without_feature_is_still_a_feature_rename(tmp_path, capsys):
    core4 = _core4(tmp_path, declared=False, source=f'pub const OLD: &str = "{MARKER}";\n')
    assert _run(core4, _checker(tmp_path)) == 1
    assert "feature was renamed" in capsys.readouterr().err


def test_inline_literal_in_live_code_is_live(tmp_path):
    assert _declared(tmp_path, f'fn drill() {{ let _ = std::env::var_os("{MARKER}"); }}\n') == 0


# --- infra#1038 R2: only a pure `test` / `all(test, ..)` cfg is test-only ----------------------

@pytest.mark.parametrize(
    "cfg",
    ['any(test, feature = "x")', 'any(feature = "x", test)', "any(test, not(test))", "not(test)",
     'feature = "panic-drill"', 'all(feature = "p2p", feature = "panic-drill")'],
)
def test_cfg_that_can_hold_outside_tests_is_live(tmp_path, cfg):
    source = (RENAMED + f'#[cfg({cfg})]\nconst PANIC_DRILL_ENV: &str = "{MARKER}";\n'
              + "fn drill() { let _ = PANIC_DRILL_ENV; }\n")
    assert _declared(tmp_path, source) == 0


@pytest.mark.parametrize(
    "cfg", ["test", "all(test)", 'all(test, feature = "p2p")', "any(test, test)", "all(any(test), not(unix))"],
)
def test_cfg_that_only_holds_in_tests_is_blind(tmp_path, cfg):
    source = (RENAMED + f'#[cfg({cfg})]\nconst OLD: &str = "{MARKER}";\n')
    assert _declared(tmp_path, source) == 1


def test_malformed_cfg_fails_closed(tmp_path):
    source = RENAMED + f'#[cfg(any(test, )]\nconst OLD: &str = "{MARKER}";\n'
    assert _declared(tmp_path, source) == 1


# --- infra#1038 re-review (Sol): initializer nesting and strict cfg grammar -------------------

@pytest.mark.parametrize(
    "init",
    [f'{{ "{MARKER}" }}', f'["{MARKER}"][0]', f'if true {{ "x" }} else {{ "{MARKER}" }}', f'("{MARKER}")'],
    ids=["braced", "array-index", "if-else-block", "parenthesised"],
)
def test_unread_const_with_nested_initializer_is_dead(tmp_path, init, capsys):
    assert _declared(tmp_path, f"pub const OLD: &str = {init};\n") == 1
    assert "dead" in capsys.readouterr().err


def test_unread_const_with_array_type_is_dead(tmp_path):
    assert _declared(tmp_path, f'const OLD: [&str; 1] = ["{MARKER}"];\n') == 1


def test_read_const_with_braced_initializer_is_live(tmp_path):
    assert _declared(tmp_path, f'const E: &str = {{ "{MARKER}" }};\n' + "fn go() { let _ = E; }\n") == 0


def test_generic_const_param_and_static_lifetime_are_not_items(tmp_path):
    source = (f'fn f<const N: usize>() {{ let _: &\'static str = "{MARKER}"; }}\n')
    assert _declared(tmp_path, source) == 0


@pytest.mark.parametrize("cfg", ["test garbage", 'any(test feature = "x")', "all(test unix)", "any(test,, unix)",
                                 "not()", "not(test, unix)", "foo(test)", 'feature =', "", "test)", "(test)"],
                         ids=lambda c: c or "empty")
def test_malformed_cfg_fails_closed_even_with_a_live_reference(tmp_path, cfg, capsys):
    source = (f'#[cfg({cfg})]\nconst OLD: &str = "{MARKER}";\nfn go() {{ let _ = OLD; }}\n')
    assert _declared(tmp_path, source) == 1
    assert "malformed cfg" in capsys.readouterr().err


@pytest.mark.parametrize("cfg", ["test,", 'any(test, feature = "x",)', "all(test, unix,)", "not(test,)",
                                 'all(any(unix, windows), not(test), feature = "p2p")',
                                 "any(all(test), not(unix))", "  all( test , unix )  "])
def test_valid_cfg_grammar_is_not_rejected(tmp_path, cfg, capsys):
    source = (f'#[cfg({cfg})]\nconst OLD: &str = "{MARKER}";\nfn go() {{ let _ = OLD; }}\n')
    assert _declared(tmp_path, source) in (0, 1)
    assert "malformed" not in capsys.readouterr().err


def test_trailing_comma_test_only_cfg_is_blind(tmp_path):
    assert _declared(tmp_path, f'#[cfg(test,)]\nconst OLD: &str = "{MARKER}";\n') == 1


def test_trailing_comma_any_with_live_arm_is_live(tmp_path):
    source = (f'#[cfg(any(test, feature = "x",))]\nconst OLD: &str = "{MARKER}";\n'
              "fn go() { let _ = OLD; }\n")
    assert _declared(tmp_path, source) == 0
