import json
import os
import subprocess
import unittest
from pathlib import Path


FILTER = Path(
    os.environ.get(
        "CRATEDIGGER_WORLD_AUDIT_PROTOCOL",
        Path(__file__).resolve().parents[2]
        / "modules/nixos/ci/scripts/cratedigger-world-audit-protocol.jq",
    )
)


def report(strict_status: str) -> dict[str, object]:
    return {
        "status": "tracked_debt",
        "strict_status": strict_status,
        "strict_violations": 1,
        "approved_total": 1,
        "known_remaining": 1,
        "newly_converged": 0,
        "converged_total": 0,
        "new_members": 0,
        "changed_members": 0,
        "growth": 0,
        "state_updated": False,
        "non_gating_violations": 2,
        "non_gating_by_code": [
            {"code": "evidence_fingerprint_mismatch", "count": 2},
        ],
        "by_code": [
            {
                "code": "current_evidence_missing",
                "approved": 1,
                "current": 1,
                "known_remaining": 1,
                "newly_converged": 0,
                "new_members": 0,
                "changed_members": 0,
            }
        ],
    }


class CratediggerWorldAuditProtocolTests(unittest.TestCase):
    def validate(self, payload: dict[str, object]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["jq", "-ce", "-f", str(FILTER)],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_accepts_every_current_strict_audit_status(self) -> None:
        for strict_status in ("clean", "integrity_failed", "observations_only"):
            with self.subTest(strict_status=strict_status):
                result = self.validate(report(strict_status))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["strict_status"], strict_status)

    def test_rejects_retired_strict_audit_status(self) -> None:
        result = self.validate(report("violations"))
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_malformed_numeric_fields(self) -> None:
        payload = report("observations_only")
        payload["strict_violations"] = "1"
        result = self.validate(payload)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
