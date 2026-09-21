#!/usr/bin/env python3
"""Focused tests for voice-diary recording readiness."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


os.environ.setdefault("VOICE_DIARY_INBOX_DIR", "/tmp/voice-diary-test-inbox")
os.environ.setdefault("VOICE_DIARY_DROP_DIR", "/tmp/voice-diary-test-drop")
os.environ.setdefault("VOICE_DIARY_WHISPER_URL", "http://127.0.0.1:9/transcribe")

SCRIPT = Path(__file__).parents[1] / "scripts" / "voice-diary-ingest.py"
SPEC = importlib.util.spec_from_file_location("voice_diary_ingest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
voice_diary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(voice_diary)


class RecordingReadinessTests(unittest.TestCase):
    @mock.patch.object(voice_diary.subprocess, "run")
    def test_missing_moov_is_unfinalized(self, run: mock.Mock) -> None:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="moov atom not found\n"
        )

        self.assertTrue(voice_diary.is_unfinalized_mp4(Path("recording.m4a")))

    @mock.patch.object(voice_diary.subprocess, "run")
    def test_valid_m4a_is_ready(self, run: mock.Mock) -> None:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="123.4\n", stderr=""
        )

        self.assertFalse(voice_diary.is_unfinalized_mp4(Path("recording.m4a")))

    @mock.patch.object(voice_diary.subprocess, "run")
    def test_other_probe_errors_remain_failures(self, run: mock.Mock) -> None:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="Permission denied\n"
        )

        self.assertFalse(voice_diary.is_unfinalized_mp4(Path("recording.m4a")))

    @mock.patch.object(voice_diary.subprocess, "run")
    def test_non_mp4_formats_are_not_probed(self, run: mock.Mock) -> None:
        self.assertFalse(voice_diary.is_unfinalized_mp4(Path("recording.opus")))
        run.assert_not_called()

    def test_unfinalized_recording_leaves_service_healthy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            drop = root / "drop"
            inbox = root / "inbox"
            drop.mkdir()
            (drop / "paused.m4a").write_bytes(b"unfinished")

            with (
                mock.patch.object(voice_diary, "DROP_DIR", drop),
                mock.patch.object(voice_diary, "INBOX_DIR", inbox),
                mock.patch.object(voice_diary, "FROM_INBOX", False),
                mock.patch.object(voice_diary, "MIN_AGE", 0),
                mock.patch.object(voice_diary, "is_unfinalized_mp4", return_value=True),
                mock.patch.object(voice_diary, "transcribe") as transcribe,
            ):
                self.assertEqual(voice_diary.main(), 0)
                transcribe.assert_not_called()


if __name__ == "__main__":
    unittest.main()
