"""Check the generated endpoint contract using the actual edge source."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class EndpointAuth(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "endpoints.md"
            env = {**os.environ, "OUTPUT_FILE": str(output)}
            subprocess.run(["bash", str(ROOT / "testnet/scripts/render-public-endpoints.sh")], env=env, check=True, capture_output=True)
            cls.rows = output.read_text().splitlines()

    def row(self, path):
        matches = [line for line in self.rows if f"| `GET` | `{path}` |" in line]
        self.assertEqual(len(matches), 1)
        return matches[0]

    def test_phone_status_requires_the_callers_wallet_session(self):
        row = self.row("/api/weather/stations/mobile")
        self.assertIn("wallet JWT (own station only)", row)
        self.assertNotIn("none/read-only", row)

    def test_status_snapshot_remains_anonymous_read_only(self):
        self.assertIn("none/read-only", self.row("/status.json"))

    def test_phone_status_keeps_the_exact_query_boundary(self):
        self.assertIn("query string must be exactly none (anything else 404s)", self.row("/api/weather/stations/mobile"))

    def test_phone_posts_require_a_bearer_and_no_query(self):
        expected = {
            "/api/weather/stations/mobile/challenge": 1,
            "/api/weather/stations/mobile": 1,
            "/api/oracle/submit-data/prepare": 1,
            "/api/oracle/submit-data": 2,  # multipart (10 MB) and plain (2 MB) variants
        }
        for path, count in expected.items():
            rows = [line for line in self.rows if f"| `POST` | `{path}` |" in line]
            self.assertEqual(len(rows), count, path)
            for row in rows:
                self.assertIn("only with an `Authorization: Bearer` header", row)
                self.assertIn("query string must be exactly none (anything else 404s)", row)
                self.assertNotIn("read-only", row)

if __name__ == "__main__":
    unittest.main()
