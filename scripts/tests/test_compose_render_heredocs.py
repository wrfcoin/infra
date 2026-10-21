"""Execute heredoc fixtures with Docker argv doubles, then check production discovery."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCANNER = ROOT / "testnet/tests/check-compose-render-inventory.py"
RENDER = "docker compose -f testnet/docker-compose.testnet.yml config"
ARGV = ["compose", "-f", "testnet/docker-compose.testnet.yml", "config"]


class ComposeHeredocTest(unittest.TestCase):
    def check_snippet(self, body, accepted, executes=True):
        with tempfile.TemporaryDirectory(prefix="compose-heredoc-") as directory:
            work = Path(directory)
            bins = work / "bin"
            bins.mkdir()
            shim = bins / "docker"
            shim.write_text(
                "#!/usr/bin/env python3\nimport json, os, sys\n"
                "with open(os.environ['ARGV_LOG'], 'a') as f:\n"
                "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            )
            shim.chmod(0o755)
            argv_log = work / "argv.jsonl"
            snippet = work / "snippet.sh"
            snippet.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body + "\n")
            env = dict(os.environ, PATH=f"{bins}:{os.environ['PATH']}",
                       ARGV_LOG=str(argv_log), WRFCOIN_RENDER_DISCOVERY_EXTRA=str(snippet))
            execution = subprocess.run(["bash", str(snippet)], cwd=work, env=env,
                                       capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            calls = [json.loads(line) for line in argv_log.read_text().splitlines()] if argv_log.exists() else []
            self.assertEqual(calls, [ARGV] if executes else [])
            scan = subprocess.run(["python3", str(SCANNER)], cwd=ROOT, env=env,
                                  capture_output=True, text=True, timeout=30)
            self.assertEqual(scan.returncode, 0 if accepted else 1, scan.stdout + scan.stderr)
            if not accepted:
                self.assertIn(str(snippet), scan.stderr)

    def test_continued_second_terminator_is_not_a_raw_marker(self):
        self.check_snippet(
            "cat <<EOF \\\n  <<'# raw-render-reviewed: continued-second'\n"
            "first\nEOF\nsecond\n# raw-render-reviewed: continued-second\n" + RENDER, False)

    def test_continued_second_terminator_is_not_a_dynamic_marker(self):
        self.check_snippet(
            "cmd='" + RENDER + "'\n"
            "cat <<EOF \\\n  <<'# dynamic-payload-reviewed: continued-dynamic'\n"
            "first\nEOF\nsecond\n# dynamic-payload-reviewed: continued-dynamic\neval \"$cmd\"", False)

    def test_genuine_marker_after_continued_heredocs(self):
        self.check_snippet(
            "cat <<EOF \\\n  <<'SECOND'\nfirst\nEOF\nsecond\nSECOND\n"
            "# raw-render-reviewed: genuine-continued\n" + RENDER, True)

    def test_genuine_marker_after_tab_stripped_continued_heredocs(self):
        self.check_snippet(
            "cat <<-EOF \\\n  <<-'SECOND'\n\tfirst\n\tEOF\n\tsecond\n\tSECOND\n"
            "# raw-render-reviewed: genuine-tab-continued\n" + RENDER, True)

    def test_quoted_heredoc_data_does_not_execute_or_create_markers(self):
        self.check_snippet(
            "cat <<'EOF' \\\n  <<'SECOND'\n" + RENDER + "\nEOF\n"
            "# raw-render-reviewed: quoted-body-data\n" + RENDER + "\nSECOND", True, False)

    def test_unquoted_second_heredoc_substitution_executes(self):
        self.check_snippet(
            "cat <<'FIRST' \\\n  <<SECOND\nliteral\nFIRST\n$(" + RENDER + ")\nSECOND", False)

    def test_shell_consumes_last_heredoc_as_script(self):
        self.check_snippet(
            "bash <<'FIRST' \\\n  <<'SECOND'\ntrue\nFIRST\n" + RENDER + "\nSECOND", False)

    def test_discarded_quoted_heredoc_is_data_for_shell(self):
        self.check_snippet("bash <<'FIRST' <<'SECOND'\n" + RENDER +
                           "\nFIRST\ntrue\nSECOND", True, False)

    def test_discarded_unquoted_heredoc_still_expands_substitution(self):
        self.check_snippet("bash <<FIRST <<'SECOND'\n$(" + RENDER +
                           ")\nFIRST\ntrue\nSECOND", False)

    def test_distinct_shell_consumers_keep_their_own_stdin(self):
        self.check_snippet("bash <<'FIRST'; bash <<'SECOND'\n" + RENDER +
                           "\nFIRST\ntrue\nSECOND", False)

    def test_inert_heredoc_marker_does_not_duplicate_real_id(self):
        self.check_snippet("cat <<'EOF'\n# raw-render-reviewed: inert-duplicate-hd\nEOF\n"
                           "# raw-render-reviewed: inert-duplicate-hd\n" + RENDER, True)

    def test_inert_quoted_marker_does_not_duplicate_real_id(self):
        self.check_snippet("message='\n# raw-render-reviewed: inert-duplicate-q\n'\n"
                           "# raw-render-reviewed: inert-duplicate-q\n" + RENDER, True)

    def test_comment_apostrophe_does_not_hide_later_render(self):
        self.check_snippet("# the gate's own fixtures\n" + RENDER, False)


    def test_comment_backslash_does_not_continue_a_heredoc_declaration(self):
        self.check_snippet(
            ": <<'# raw-render-reviewed: comment-backslash' # ignored \\\n"
            "body\n# raw-render-reviewed: comment-backslash\n" + RENDER, False)

    def test_escaped_backslash_does_not_continue_a_heredoc_declaration(self):
        self.check_snippet(
            ": <<'# raw-render-reviewed: escaped-backslash' \\\\\n"
            "body\n# raw-render-reviewed: escaped-backslash\n" + RENDER, False)

    def test_operator_delimiter_split_by_continuation(self):
        self.check_snippet(
            ": <<EOF \\\n  <<\\\n '# raw-render-reviewed: split-delimiter'\n"
            "first\nEOF\nsecond\n# raw-render-reviewed: split-delimiter\n" + RENDER, False)

    def test_tab_stripped_marker_terminator_is_data(self):
        self.check_snippet(
            ": <<-EOF \\\n  <<-'# raw-render-reviewed: tab-terminator'\n"
            "\tfirst\n\tEOF\n\tsecond\n\t# raw-render-reviewed: tab-terminator\n" + RENDER, False)

    def test_spaces_do_not_terminate_an_ordinary_heredoc(self):
        self.check_snippet(
            ": <<'EOF'\n  EOF\n# raw-render-reviewed: indented-false-terminator\nEOF\n" + RENDER, False)

    def test_unsupported_concatenated_delimiter_refuses_marker_exemption(self):
        self.check_snippet(
            ": <<'E'OF\nbody\nEOF\n# raw-render-reviewed: unsupported-concatenation\n" + RENDER, False)


if __name__ == "__main__":
    unittest.main()
