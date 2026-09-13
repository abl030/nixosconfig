"""Exercise dashboard routing without a daemon, credentials, or model calls."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    calls = root / "calls.jsonl"
    stub = root / "stub"
    stub.write_text(
        f"#!{sys.executable}\n"
        "import json, os, sys\n"
        f"with open({str(calls)!r}, 'a') as log:\n"
        "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
        "if sys.argv[1] == 'systemctl':\n"
        "    sys.exit(int(os.environ.get('CODEX_TEST_START_FAILURE', '0')))\n"
    )
    stub.chmod(0o700)
    expected_home = os.environ["HOME"] + "/.codex"
    script = "set -euo pipefail\n" + Path(sys.argv[1]).read_text()
    for key, value in {
        "@codex@": f"{stub} codex",
        "@systemctl@": f"{stub} systemctl",
        "@codexHome@": expected_home,
    }.items():
        script = script.replace(key, value)
    launcher = root / "launcher.sh"
    launcher.write_text(script)

    def run(args, *, managed=False, overrides=None, exit_code=0):
        calls.write_text("")
        env = dict(os.environ, CODEX_HOME=expected_home, XDG_RUNTIME_DIR=str(root))
        env.update(overrides or {})
        result = subprocess.run(["bash", str(launcher), *args], env=env, capture_output=True)
        assert result.returncode == exit_code, result.stderr.decode()
        actual = [json.loads(line) for line in calls.read_text().splitlines()]
        start = [["systemctl", "--user", "start", "codex-app-server.service"]]
        remote = ["--remote", f"unix://{root}/codex-app-server/control.sock"]
        defaults = ["--config", "approval_policy=never", "--config", "sandbox_mode=danger-full-access"]
        expected = start + [["codex", *defaults, *args, *remote]] if managed else [["codex", *args]]
        if exit_code:
            expected = start
        assert actual == expected, (actual, expected)

    run(["agents"], managed=True)
    run(["agents", "-c", 'model="example model"', "--no-alt-screen"], managed=True)
    run(["agents", "-c", "approval_policy=on-request", "-c", "sandbox_mode=workspace-write"], managed=True)
    run(["agents", "--remote", "unix:///chosen/socket"])
    run(["agents", "--remote=unix:///chosen/socket"])
    run(["agents", "--help"])
    run(["agents"], overrides={"CODEX_HOME": str(root / "other-home")})
    run(["--version"])
    run(["app-server", "--listen", "stdio://"])
    run(["exec", "agents"])
    run([])
    run(["agents"], overrides={"CODEX_TEST_START_FAILURE": "7"}, exit_code=7)

print("Codex dashboard routing: 12 cases passed")
