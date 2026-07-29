import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(
    os.environ.get(
        "CRATEDIGGER_DAILY_SUMMARY",
        Path(__file__).resolve().parents[2]
        / "modules/nixos/ci/scripts/cratedigger-daily-summary.py",
    )
)


class CratediggerDailySummaryTests(unittest.TestCase):
    def summarize(self, text: str, invocation: str = "abc123") -> str:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--invocation-id", invocation],
            input=text,
            text=True,
            capture_output=True,
            check=True,
        )
        return result.stdout

    def test_large_journal_becomes_bounded_actionable_summary(self) -> None:
        progress = "\n".join(f"PROGRESS {i}/2781 targets" for i in range(1200))
        audit = json.dumps(
            {
                "status": "tracked_debt",
                "strict_violations": 653,
                "known_remaining": 653,
                "newly_converged": 3,
                "new_members": 0,
                "changed_members": 0,
                "growth": 0,
                "by_code": [{"code": "x", "members": ["x" * 80] * 20}],
            }
        )
        journal = f"""daily unstable gate: cloning https://github.com/abl030/cratedigger.git branch main
daily unstable gate: updating flake.lock
• Updated input 'nixpkgs':
    'github:NixOS/nixpkgs/old' (2026-07-26)
  → 'github:NixOS/nixpkgs/new' (2026-07-29)
/tmp/repo/tests/a.py:10:5 - error: Argument of type \"int | None\" is invalid
/tmp/repo/tests/a.py:10:5 - error: Argument of type \"int | None\" is invalid
{progress}
python: tests.test_contract | 1 failed test IDs | rerun: python3 -m unittest tests.test_contract.test_exact | log: /run/private/python.log
fuzz burst: ALL GREEN (100 modules, 1194 tests, 960.0s)
=== daily candidate summary ===
FAIL whole-repository Pyright (exit 1)
FAIL deterministic full suite (exit 1)
PASS Nix flake checks
PASS world-model burst
PASS generated fuzz burst
PASS mirror-harness smoke
daily unstable gate: candidate failed; flake.lock was not committed
{audit}
PASS live world audit: known debt is stable or shrinking
"""
        output = self.summarize(journal)
        self.assertIn("Candidate lock: updated for testing; not committed", output)
        self.assertIn("FAIL whole-repository Pyright (exit 1)", output)
        self.assertIn("tests/a.py:10:5 - error:", output)
        self.assertEqual(output.count("tests/a.py:10:5 - error:"), 1)
        self.assertIn("tests.test_contract.test_exact", output)
        self.assertIn("fuzz burst: ALL GREEN", output)
        self.assertIn("Live-world audit: 653 known; 3 converged; 0 new; 0 changed; growth 0", output)
        self.assertIn("_SYSTEMD_INVOCATION_ID=abc123", output)
        self.assertNotIn("PROGRESS", output)
        self.assertLessEqual(len(output), 6000)

    def test_early_failure_is_not_hidden(self) -> None:
        output = self.summarize(
            "daily unstable gate: cloning repo branch main\n"
            "fatal: unable to access repo\n"
            "daily unstable gate: clone failed\n"
        )
        self.assertIn("daily unstable gate: clone failed", output)
        self.assertIn("fatal: unable to access repo", output)

    def test_truncation_preserves_full_journal_lookup(self) -> None:
        errors = "\n".join(
            f"tests/test_{i}.py:1:1 - error: {'x' * 480}" for i in range(30)
        )
        output = self.summarize(errors)
        self.assertIn("summary truncated", output)
        self.assertIn("_SYSTEMD_INVOCATION_ID=abc123", output)
        self.assertLessEqual(len(output), 6000)

    def test_live_world_failures_are_explicit(self) -> None:
        failures = (
            "live world audit: invalid tracked JSON report (remote exit 255)\n"
            "live world audit: exit/status protocol mismatch (remote exit 2)\n"
            "FAIL live world audit: new or changed violations (exit 1)\n"
        )
        output = self.summarize(failures)
        for line in failures.splitlines():
            self.assertIn(line, output)


if __name__ == "__main__":
    unittest.main()
