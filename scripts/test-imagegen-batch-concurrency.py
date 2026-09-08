#!/usr/bin/env python3
"""Exercise the embedded batch shell with inference/mount checks stubbed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "hosts/imagegen/configuration-lxc.nix"


class BatchConcurrencyTest(unittest.TestCase):
    def check_batch(self, queue, parallel, expected):
        source = SOURCE.read_text().split("    text = ''\n", 1)[1].split("\n    '';", 1)[0]
        source = source.replace("''${", "${")
        with tempfile.TemporaryDirectory(prefix="imagegen-concurrency-") as root:
            root = Path(root)
            out = root / "out"
            settings = root / "settings"
            bins = root / "bin"
            for directory in (out, settings, bins):
                directory.mkdir()
            (out / "queue.txt").write_text(queue)
            (settings / "settings.env").write_text(f"PARALLEL={parallel}\n")
            for name, body in {
                "mountpoint": "exit 0\n",
                "xargs": 'printf "DISPATCH %s\\n" "$*"; cat >/dev/null\n',
            }.items():
                path = bins / name
                path.write_text("#!/bin/sh\n" + body)
                path.chmod(0o755)
            source = source.replace("OUT=/mnt/out", f'OUT="{out}"')
            source = source.replace("QUEUE=/var/lib/imagegen/queue", f'QUEUE="{settings}"')
            script = root / "batch"
            script.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + source)
            result = subprocess.run(
                ["bash", str(script)], text=True, capture_output=True,
                env={**os.environ, "PATH": str(bins) + ":" + os.environ["PATH"]},
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            dispatch = next(line for line in result.stdout.splitlines() if line.startswith("DISPATCH "))
            self.assertIn(f"-P {expected} ", dispatch)

    def test_generation_retains_parallelism(self):
        self.check_batch("apple\npear\n", 2, 2)

    def test_edit_batch_is_serial(self):
        self.check_batch("in/a.jpg :: sunset\nin/b.jpg :: dawn\n", 2, 1)

    def test_mixed_batch_is_serial_even_with_override(self):
        self.check_batch("apple\nin/a.jpg :: sunset\npear\n", 8, 1)

    def test_comment_is_not_an_edit(self):
        self.check_batch("# in/a.jpg :: example\napple\n", 2, 2)


if __name__ == "__main__":
    unittest.main()
