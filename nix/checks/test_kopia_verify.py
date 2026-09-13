"""Verify streaming output and failure propagation without scanning a repository."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest


class VerifyTest(unittest.TestCase):
    def test_failure_handler_reports_systemd_timeout_context(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "curl"
            fake.write_text(
                "#!" + os.sys.executable + "\n"
                "import os,sys,pathlib\n"
                "payload=sys.argv[sys.argv.index('--data-binary')+1]\n"
                "pathlib.Path(os.environ['TEST_PAYLOAD']).write_text(payload)\n"
            )
            fake.chmod(0o700)
            script = Path(shlex.split(os.environ["KOPIA_NOTIFY_SCRIPT"])[0]).read_text()
            runner = root / "notify"
            runner.write_text(script.replace(os.environ["KOPIA_CURL_BIN"], str(fake)))
            runner.chmod(0o700)
            payload_file = root / "payload.json"
            result = subprocess.run(
                [str(runner)],
                env={
                    **os.environ,
                    "MONITOR_SERVICE_RESULT": "timeout",
                    "MONITOR_EXIT_CODE": "killed",
                    "MONITOR_EXIT_STATUS": "15",
                    "TEST_PAYLOAD": str(payload_file),
                },
                capture_output=True, text=True, timeout=5, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(payload_file.read_text())
            self.assertIn("result=timeout", payload["message"])
            self.assertIn("code=killed", payload["message"])
            self.assertIn("status=15", payload["message"])
            self.assertEqual(payload["priority"], 8)

    def test_progress_is_visible_before_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "kopia"
            fake.write_text(
                "#!/bin/sh\n"
                "echo 'verification progress marker'\n"
                "sleep 2\n"
                "echo 'Finished processing 10 objects (1 GB). Read 2 files (1 MB).'\n"
            )
            fake.chmod(0o700)
            runner = self.runner(root, fake)
            output = root / "journal"
            with output.open("w") as stream:
                process = subprocess.Popen(
                    [str(runner)], stdout=stream, stderr=subprocess.STDOUT,
                    env={**os.environ, "RUNTIME_DIRECTORY": str(root)},
                )
                try:
                    deadline = time.monotonic() + 1.5
                    while time.monotonic() < deadline:
                        if "verification progress marker" in output.read_text():
                            break
                        time.sleep(0.02)
                    self.assertIn("verification progress marker", output.read_text())
                    self.assertIsNone(process.poll(), "progress was buffered until exit")
                    self.assertEqual(process.wait(timeout=5), 0)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            self.assertIn("exit_code=0", output.read_text())
            self.assertIn("summary=Finished processing", output.read_text())

    def test_failure_reaches_systemd(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "kopia"
            fake.write_text("#!/bin/sh\necho 'verification failed' >&2\nexit 7\n")
            fake.chmod(0o700)
            result = subprocess.run(
                [str(self.runner(root, fake))],
                env={**os.environ, "RUNTIME_DIRECTORY": str(root)},
                capture_output=True, text=True, timeout=5, check=False,
            )
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertIn("verification failed", result.stdout)
            self.assertIn("exit_code=7", result.stdout)

    @staticmethod
    def runner(root, fake):
        # Substitute only the external Kopia executable. Run the generated
        # wrapper, tee, summary parsing and exit handling unchanged.
        script = Path(os.environ["KOPIA_VERIFY_SCRIPT"]).read_text()
        script = script.replace(os.environ["KOPIA_REAL_BIN"], str(fake))
        path = root / "verify"
        path.write_text(script)
        path.chmod(0o700)
        return path


if __name__ == "__main__":
    unittest.main()
