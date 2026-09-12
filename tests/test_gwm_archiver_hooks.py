"""Exercise the evaluated notification script with fake network/journal tools."""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(os.environ.get("GWM_PICKUP_SCRIPT"), "run through gwmArchiverCheck")
class PickupTests(unittest.TestCase):
    def run_hook(self, lines, token=True, result="success"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root / "calls"
            fixture = root / "journal"
            fixture.write_text(lines)
            token_file = root / "token"
            if token:
                token_file.write_text("test-token")
            for name in ("journalctl", "wakeonlan", "ssh", "curl"):
                tool = root / name
                tool.write_text(
                    "#!/bin/sh\n"
                    'printf "%s %s\\n" "$(basename "$0")" "$*" >> "$CALLS"\n'
                    'if [ "$(basename "$0")" = journalctl ]; then\n'
                    '  [ "$1" = "_SYSTEMD_INVOCATION_ID=current-run" ] || exit 1\n'
                    '  cat "$FIXTURE"\n'
                    'fi\n'
                )
                tool.chmod(0o755)
            source = Path(os.environ["GWM_PICKUP_SCRIPT"]).read_text()
            source = re.sub(r"/nix/store/[^\s]+/bin/(ssh|wakeonlan|curl)",
                            lambda match: str(root / match[1]), source)
            script = root / "pickup"
            script.write_text(source)
            env = os.environ | {
                "PATH": f"{root}:{os.environ['PATH']}", "CALLS": str(calls),
                "FIXTURE": str(fixture), "GOTIFY_TOKEN_FILE": str(token_file),
                "MONITOR_INVOCATION_ID": "current-run",
                "MONITOR_SERVICE_RESULT": result,
            }
            subprocess.run(["bash", str(script)], env=env, check=True, capture_output=True)
            return calls.read_text()

    def test_noop_uses_only_current_invocation_and_does_not_wake(self):
        calls = self.run_hook("summary: {'skip-complete': 111}\n")
        self.assertIn("_SYSTEMD_INVOCATION_ID=current-run", calls)
        self.assertNotIn("wakeonlan", calls)
        self.assertNotIn("curl", calls)

    def test_failed_sweep_still_delivers_completed_issue(self):
        calls = self.run_hook("NEW_ISSUE: #752 downloaded\nsummary: error\n", result="exit-code")
        self.assertIn("wakeonlan", calls)
        self.assertIn("ssh", calls)
        self.assertIn("curl", calls)
        self.assertLess(calls.index("ssh"), calls.index("curl"))

    def test_missing_gotify_token_does_not_suppress_conversion(self):
        calls = self.run_hook("NEW_ISSUE: #752 downloaded\n", token=False)
        self.assertIn("ssh", calls)
        self.assertNotIn("curl", calls)


if __name__ == "__main__":
    unittest.main()
