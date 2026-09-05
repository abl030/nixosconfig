#!/usr/bin/env python3
"""Behavioral tests for the trace-safe Forgejo authentication boundary."""

from __future__ import annotations

import os
import ctypes
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
HELPER = Path(os.environ.get("FORGEJO_AUTH_HELPER", ROOT / "scripts/forgejo-auth.sh"))
EXPECTED_REPOSITORY = "https://git.ablz.au/abl030/nixosconfig.git"
EXPECTED_API = "https://git.ablz.au/api/v1/repos/abl030/nixosconfig"
FIXTURE_TOKEN = "F" * 40


FAKE_GIT = r'''#!/usr/bin/env bash
set -u

: "${FAKE_GIT_LOG:?}"
{
  printf 'argv'
  for arg in "$@"; do
    printf ' <%s>' "$arg"
  done
  printf '\n'
} >>"$FAKE_GIT_LOG"

is_remote=0
is_push_urls=0
is_push=0
for arg in "$@"; do
  case "$arg" in
    remote) is_remote=1 ;;
    --push) is_push_urls=1 ;;
    push) is_push=1 ;;
  esac
done

if [ "$is_remote" -eq 1 ]; then
  if [ "$is_push_urls" -eq 1 ]; then
    printf '%s' "${FAKE_PUSH_OUTPUT-}"
  else
    printf '%s' "${FAKE_FETCH_OUTPUT-}"
  fi
  exit 0
fi

if [ "$is_push" -eq 1 ]; then
  : "${FAKE_PUSH_AUTH_CAPTURE:?}"
  : "${FAKE_PUSH_ENV_CAPTURE:?}"
  : "${FAKE_PUSH_STARTED:?}"
  printf '%s' "${GIT_CONFIG_VALUE_0-}" >"$FAKE_PUSH_AUTH_CAPTURE"
  {
    for name in GIT_TRACE GIT_TRACE_PACKET GIT_TRACE_PERFORMANCE GIT_TRACE_SETUP \
      GIT_TRACE_SHALLOW GIT_TRACE_CURL GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF \
      GIT_TRACE2_BRIEF GIT_TRACE2_CONFIG_PARAMS GIT_CURL_VERBOSE CURL_VERBOSE; do
      if printenv "$name" >/dev/null 2>&1; then
        printf '%s=present\n' "$name"
      else
        printf '%s=unset\n' "$name"
      fi
    done
  } >"$FAKE_PUSH_ENV_CAPTURE"
  touch "$FAKE_PUSH_STARTED"
  if [ "${FAKE_PUSH_BLOCK-0}" = 1 ]; then
    : "${FAKE_PUSH_RELEASE:?}"
    while [ ! -e "$FAKE_PUSH_RELEASE" ]; do
      sleep 0.02
    done
  fi
  exit "${FAKE_PUSH_RC:-0}"
fi

printf 'unexpected fake git invocation\n' >&2
exit 99
'''


FAKE_CURL = r'''#!/usr/bin/env bash
set -u

: "${FAKE_CURL_ARGS_CAPTURE:?}"
: "${FAKE_CURL_CONFIG_CAPTURE:?}"
: "${FAKE_CURL_ENV_CAPTURE:?}"
config=""
{
  printf 'argv'
  while [ "$#" -gt 0 ]; do
    printf ' <%s>' "$1"
    if [ "$1" = "--config" ]; then
      config="$2"
    fi
    shift
  done
  printf '\n'
} >"$FAKE_CURL_ARGS_CAPTURE"
if [ -n "$config" ]; then
  while IFS= read -r line; do
    printf '%s\n' "$line"
  done <"$config" >"$FAKE_CURL_CONFIG_CAPTURE"
else
  : >"$FAKE_CURL_CONFIG_CAPTURE"
fi
{
  for name in CURL_VERBOSE CURL_TRACE CURL_TRACE_ASCII CURL_TRACE_CONFIG; do
    if printenv "$name" >/dev/null 2>&1; then
      printf '%s=present\n' "$name"
    else
      printf '%s=unset\n' "$name"
    fi
  done
} >"$FAKE_CURL_ENV_CAPTURE"
printf '{"ok":true}\n' >&4
printf '200'
exit "${FAKE_CURL_RC:-0}"
'''


class ForgejoAuthBoundaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="forgejo-auth-test-")
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.token_file = self.root / "token"
        self.token_file.write_text(FIXTURE_TOKEN)
        self.git_log = self.root / "git.log"
        self.git_auth = self.root / "git-auth"
        self.git_env = self.root / "git-env"
        self.git_started = self.root / "git-started"
        self.git_release = self.root / "git-release"
        self.curl_args = self.root / "curl-args"
        self.curl_config = self.root / "curl-config"
        self.curl_env = self.root / "curl-env"
        self._install_fake("git", FAKE_GIT)
        self._install_fake("curl", FAKE_CURL)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _install_fake(self, name: str, source: str) -> None:
        path = self.bin / name
        bash = shutil.which("bash") or "/bin/bash"
        path.write_text(source.replace("#!/usr/bin/env bash", f"#!{bash}", 1))
        path.chmod(0o755)

    def _env(self, **extra: str) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin}:{env['PATH']}",
                "FAKE_GIT_LOG": str(self.git_log),
                "FAKE_PUSH_AUTH_CAPTURE": str(self.git_auth),
                "FAKE_PUSH_ENV_CAPTURE": str(self.git_env),
                "FAKE_PUSH_STARTED": str(self.git_started),
                "FAKE_PUSH_RELEASE": str(self.git_release),
                "FAKE_CURL_ARGS_CAPTURE": str(self.curl_args),
                "FAKE_CURL_CONFIG_CAPTURE": str(self.curl_config),
                "FAKE_CURL_ENV_CAPTURE": str(self.curl_env),
                "FAKE_FETCH_OUTPUT": EXPECTED_REPOSITORY + "\n",
                "FAKE_PUSH_OUTPUT": EXPECTED_REPOSITORY + "\n",
                "FAKE_PUSH_RC": "0",
                "FAKE_CURL_RC": "0",
            }
        )
        env.update(extra)
        return env

    def _git_push(self, token_file: Path | None = None, **env_extra: str) -> subprocess.CompletedProcess[str]:
        token_file = token_file or self.token_file
        return subprocess.run(
            [
                "bash",
                str(HELPER),
                "git-push",
                "--repo",
                str(self.repo),
                "--remote",
                "origin",
                "--expected-fetch-url",
                EXPECTED_REPOSITORY,
                "--expected-push-url",
                EXPECTED_REPOSITORY,
                "--token-file",
                str(token_file),
                "--refspec",
                "HEAD:master",
            ],
            env=self._env(**env_extra),
            text=True,
            capture_output=True,
            check=False,
        )

    def _rest(self, token_file: Path | None = None, url: str = EXPECTED_API + "/pulls", **env_extra: str) -> subprocess.CompletedProcess[str]:
        token_file = token_file or self.token_file
        return subprocess.run(
            [
                "bash",
                str(HELPER),
                "rest",
                "--token-file",
                str(token_file),
                "--method",
                "GET",
                "--url",
                url,
            ],
            env=self._env(**env_extra),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_40_byte_eof_token_is_passed_only_as_git_config_value(self) -> None:
        result = self._git_push()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git_auth.read_text(), f"Authorization: token {FIXTURE_TOKEN}")
        self.assertNotIn(FIXTURE_TOKEN, self.git_log.read_text())
        self.assertNotIn(FIXTURE_TOKEN, result.stdout + result.stderr)

    def test_optional_final_lf_and_malformed_tokens_in_both_modes(self) -> None:
        for value in (FIXTURE_TOKEN, FIXTURE_TOKEN + "\n", "", "\n", FIXTURE_TOKEN + "\n\n", FIXTURE_TOKEN + "\r\n", "F" * 39, "G" * 40, "F" * 20 + "\n" + "F" * 20, FIXTURE_TOKEN + "\0"):
            for run in (self._git_push, self._rest):
                with self.subTest(value=repr(value), mode=run.__name__):
                    self.token_file.write_text(value)
                    result = run()
                    self.assertEqual(result.returncode == 0, value in (FIXTURE_TOKEN, FIXTURE_TOKEN + "\n"), result.stderr)
                    self.assertNotIn(FIXTURE_TOKEN, result.stdout + result.stderr)

    def test_startup_debug_trap_cannot_trace_secret_or_descendants(self) -> None:
        startup = self.root / "startup"
        startup.write_text("trap 'set -x' DEBUG\n")
        for run in (self._git_push, self._rest):
            result = run(BASH_ENV=str(startup))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(FIXTURE_TOKEN, result.stdout + result.stderr)

    def test_empty_token_fails_before_push_network(self) -> None:
        empty = self.root / "empty-token"
        empty.write_text("")
        result = self._git_push(empty)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(" <push>", self.git_log.read_text())
        self.assertFalse(self.git_auth.exists())
        self.assertNotIn(FIXTURE_TOKEN, result.stdout + result.stderr)

    def test_unreadable_token_fails_before_push_network(self) -> None:
        unreadable = self.root / "unreadable-token"
        unreadable.write_text(FIXTURE_TOKEN)
        unreadable.chmod(0)
        try:
            result = self._git_push(unreadable)
        finally:
            unreadable.chmod(0o600)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(" <push>", self.git_log.read_text())
        self.assertFalse(self.git_auth.exists())

    def test_wrong_or_multiple_remote_urls_are_rejected_before_token_read(self) -> None:
        cases = (
            ("wrong fetch", "https://git.ablz.au/abl030/other.git\n", EXPECTED_REPOSITORY + "\n"),
            ("wrong push", EXPECTED_REPOSITORY + "\n", "https://git.ablz.au/abl030/other.git\n"),
            ("multiple fetch", EXPECTED_REPOSITORY + "\n" + EXPECTED_REPOSITORY + "\n", EXPECTED_REPOSITORY + "\n"),
            ("multiple push", EXPECTED_REPOSITORY + "\n", EXPECTED_REPOSITORY + "\n" + EXPECTED_REPOSITORY + "\n"),
        )
        for name, fetch, push in cases:
            with self.subTest(name=name):
                # IN_OPEN on a regular file detects access, unlike a FIFO that
                # read_token rejects without ever opening it.
                libc = ctypes.CDLL(None, use_errno=True)
                watch = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
                self.assertGreaterEqual(watch, 0)
                self.addCleanup(os.close, watch)
                self.assertGreaterEqual(libc.inotify_add_watch(watch, os.fsencode(self.token_file), 0x20), 0)
                env = self._env(FAKE_FETCH_OUTPUT=fetch, FAKE_PUSH_OUTPUT=push)
                proc = subprocess.Popen(
                    [
                        "bash",
                        str(HELPER),
                        "git-push",
                        "--repo",
                        str(self.repo),
                        "--remote",
                        "origin",
                        "--expected-fetch-url",
                        EXPECTED_REPOSITORY,
                        "--expected-push-url",
                        EXPECTED_REPOSITORY,
                        "--token-file",
                        str(self.token_file),
                        "--refspec",
                        "HEAD:master",
                    ],
                    env=env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                try:
                    stdout, stderr = proc.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    stdout, stderr = proc.communicate()
                    self.fail(f"{name} read the token before rejecting the remote: {stdout}{stderr}")
                self.assertNotEqual(proc.returncode, 0)
                self.assertNotIn(" <push>", self.git_log.read_text())
                self.assertNotIn(FIXTURE_TOKEN, stdout + stderr)
                with self.assertRaises(BlockingIOError, msg="credential opened before URL comparison"):
                    os.read(watch, 4096)

    def test_push_exit_status_is_preserved_without_secret_output(self) -> None:
        result = self._git_push(FAKE_PUSH_RC="37")
        self.assertEqual(result.returncode, 37)
        self.assertNotIn(FIXTURE_TOKEN, result.stdout + result.stderr)

    def test_xtrace_git_trace2_and_curl_debug_are_removed_before_child(self) -> None:
        trace_file = self.root / "trace2.json"
        env = self._env(
            GIT_TRACE="1",
            GIT_TRACE2_EVENT=str(trace_file),
            GIT_TRACE2_PERF=str(self.root / "trace2.perf"),
            GIT_CURL_VERBOSE="1",
            CURL_VERBOSE="1",
        )
        proc = subprocess.Popen(
            ["bash", "-x", str(HELPER), "git-push", "--repo", str(self.repo), "--remote", "origin", "--expected-fetch-url", EXPECTED_REPOSITORY, "--expected-push-url", EXPECTED_REPOSITORY, "--token-file", str(self.token_file), "--refspec", "HEAD:master"],
            env={**env, "FAKE_PUSH_BLOCK": "1"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 2
            while not self.git_started.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.git_started.exists(), "fake push did not reach the blocked child")
            cmdline = Path(f"/proc/{proc.pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            self.assertNotIn(FIXTURE_TOKEN, cmdline)
            self.git_release.touch()
            stdout, stderr = proc.communicate(timeout=2)
        finally:
            if proc.poll() is None:
                self.git_release.touch()
                proc.kill()
                proc.communicate()
        self.assertEqual(proc.returncode, 0, stderr)
        self.assertNotIn(FIXTURE_TOKEN, stdout + stderr)
        self.assertFalse(trace_file.exists(), "Git Trace2 created an unsanitized trace artifact")
        self.assertIn("GIT_TRACE=unset", self.git_env.read_text())
        self.assertIn("GIT_TRACE2_EVENT=present", self.git_env.read_text())
        self.assertIn("GIT_CURL_VERBOSE=unset", self.git_env.read_text())

    def test_rest_uses_curl_stdin_config_not_header_argv(self) -> None:
        result = self._rest(url=EXPECTED_API + "/pulls?state=open&limit=20", CURL_VERBOSE="1", CURL_TRACE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '{"ok":true}\n')
        self.assertIn(f"Authorization: token {FIXTURE_TOKEN}", self.curl_config.read_text())
        args = self.curl_args.read_text()
        self.assertNotIn(FIXTURE_TOKEN, args)
        self.assertNotIn("--header", args)
        self.assertNotIn("-H", args)
        self.assertNotIn("--verbose", args)
        self.assertIn("CURL_VERBOSE=unset", self.curl_env.read_text())
        self.assertNotIn(FIXTURE_TOKEN, result.stdout + result.stderr)

    def test_rest_wrong_url_fails_before_token_read_and_curl(self) -> None:
        libc = ctypes.CDLL(None, use_errno=True)
        watch = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        self.assertGreaterEqual(watch, 0)
        self.addCleanup(os.close, watch)
        self.assertGreaterEqual(libc.inotify_add_watch(watch, os.fsencode(self.token_file), 0x20), 0)
        proc = subprocess.Popen(
            [
                "bash",
                str(HELPER),
                "rest",
                "--token-file",
                str(self.token_file),
                "--method",
                "GET",
                "--url",
                "https://evil.invalid/api/v1/repos/abl030/nixosconfig/pulls",
            ],
            env=self._env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            stdout, stderr = proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate()
            self.fail(f"REST boundary read the token before rejecting URL: {stdout}{stderr}")
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.curl_args.exists())
        with self.assertRaises(BlockingIOError, msg="credential opened before REST URL validation"):
            os.read(watch, 4096)

    def test_rest_exit_status_is_preserved_without_secret_output(self) -> None:
        result = self._rest(FAKE_CURL_RC="42")
        self.assertEqual(result.returncode, 42)
        self.assertNotIn(FIXTURE_TOKEN, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
