"""Execute the production Rust health probe against bounded HTTP controls."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("rustc"), "runtime health controls require an existing Rust compiler")
class DeFiHealthcheckTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if subprocess.run(["rustc", "--version"], capture_output=True,
                          check=False).returncode != 0:
            raise unittest.SkipTest("runtime health controls require a working Rust toolchain")
        cls.temp = tempfile.TemporaryDirectory()
        cls.probe = Path(cls.temp.name) / "probe"
        subprocess.run(["rustc", "--edition=2021", "-D", "warnings",
                        str(ROOT / "testnet/services/defi/healthcheck.rs"), "-o", str(cls.probe)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def check_response(self, response, expected):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(5)
            request = []

            def serve():
                with listener.accept()[0] as stream:
                    stream.settimeout(5)
                    request.append(stream.recv(1024))
                    stream.sendall(response)

            thread = threading.Thread(target=serve)
            thread.start()
            env = {"DEFI_NODE_BIND": f"0.0.0.0:{listener.getsockname()[1]}"}
            result = subprocess.run([str(self.probe)], env=env, capture_output=True, timeout=5)
            thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertTrue(request[0].startswith(b"GET /health HTTP/1.1\r\n"))
        self.assertEqual(result.returncode == 0, expected)

    def test_healthy_http_status(self):
        self.check_response(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", True)

    def test_unhealthy_status(self):
        self.check_response(b"HTTP/1.1 503 Unavailable\r\n\r\n", False)

    def test_truncated_status(self):
        self.check_response(b"HTTP/1.1 200 OK", False)

    def test_overlong_status(self):
        self.check_response(b"HTTP/1.1 200 " + b"x" * 300 + b"\r\n", False)


if __name__ == "__main__":
    unittest.main()
