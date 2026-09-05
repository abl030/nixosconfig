#!/usr/bin/env python3
"""Real Git/curl regressions, dummy credentials and loopback CONNECT/TLS only.

Adapted from the independent issue #28 review's http_probes.py. No production
DNS/transport is used: the proxy terminates TLS itself using a fresh test CA.
"""
import os
from pathlib import Path
import socketserver
import ssl
import subprocess
import tempfile
import threading
import unittest
from typing import cast

HELPER = Path(os.environ.get("FORGEJO_AUTH_HELPER", Path(__file__).parents[2] / "scripts/forgejo-auth.sh"))
TOKEN = "F" * 40
URL = "https://git.ablz.au/abl030/nixosconfig.git"
SHA = "a" * 40


def headers(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        block = sock.recv(1)
        if not block:
            raise EOFError
        data += block
    return data.decode("latin1")


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        server = cast("Server", self.server)
        self.request.settimeout(5)
        try:
            connect = headers(self.request)
            assert connect.startswith("CONNECT git.ablz.au:443 "), connect
            self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            with server.context.wrap_socket(self.request, server_side=True) as sock:
                lines = headers(sock).split("\r\n")
                attrs = dict(line.lower().split(":", 1) for line in lines[1:] if ":" in line)
                length = int(attrs.get("content-length", "0"))
                body = b""
                while len(body) < length:
                    block = sock.recv(length - len(body))
                    if not block:
                        raise EOFError
                    body += block
                auth = attrs.get("authorization", "").strip()
                server.requests.append((lines[0], auth, body))
                extra = ""
                status = "200 OK"
                data = b'{"ok":true}\n'
                if server.mode == "redirect":
                    status = "302 Found"
                    extra = "Location: https://other.invalid/elsewhere\r\n"
                    data = b""
                elif server.mode == "same-origin-redirect" and "/abl030/other.git/" not in lines[0]:
                    status = "302 Found"
                    target = lines[0].split()[1].replace("/nixosconfig.git/", "/other.git/").replace("/push-target.git/", "/other.git/")
                    extra = "Location: https://git.ablz.au" + target + "\r\n"
                    data = b""
                elif server.mode in ("private", "private-empty"):
                    if auth != "token " + TOKEN.lower():
                        status = "401 Unauthorized"
                        extra = 'WWW-Authenticate: Basic realm="private"\r\n'
                        data = b"authentication required"
                    else:
                        extra = "Content-Type: application/x-git-upload-pack-advertisement\r\n"
                        ref = (SHA + " refs/heads/snapshots\0\n").encode()
                        data = b"001e# service=git-upload-pack\n0000" + f"{len(ref)+4:04x}".encode() + ref + b"0000"
                        if server.mode == "private-empty":
                            data = b"001e# service=git-upload-pack\n00000000"
                elif ".git/" in lines[0]:
                    status = "400 Bad Request"
                    data = b"dummy Git failure"
                sock.sendall((f"HTTP/1.1 {status}\r\n{extra}Content-Length: {len(data)}\r\nConnection: close\r\n\r\n").encode() + data)
        except (EOFError, ssl.SSLError, TimeoutError, OSError) as error:
            server.errors.append(type(error).__name__)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    context: ssl.SSLContext
    requests: list[tuple[str, str, bytes]]
    errors: list[str]
    mode: str


class RealToolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="forgejo-real-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        cert, key = self.root / "cert.pem", self.root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=git.ablz.au", "-addext", "subjectAltName=DNS:git.ablz.au"], check=True, capture_output=True)
        self.server = Server(("127.0.0.1", 0), Handler)
        self.server.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.server.context.load_cert_chain(cert, key)
        self.server.requests, self.server.errors = [], []
        self.server.mode = "normal"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        proxy = "http://127.0.0.1:" + str(self.server.server_address[1])
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "CURL_", "BASH", "SHELLOPTS")) and k.lower() not in ("home", "xdg_config_home", "https_proxy", "http_proxy", "all_proxy", "no_proxy")}
        self.env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.root), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0", HTTPS_PROXY=proxy, HTTP_PROXY=proxy, ALL_PROXY=proxy, NO_PROXY="", GIT_SSL_CAINFO=str(cert), CURL_CA_BUNDLE=str(cert))
        self.token = self.root / "token"
        self.token.write_text(TOKEN)
        self.repo = self.root / "repo"
        self.git("init", "-q", str(self.repo))
        self.git("-C", str(self.repo), "remote", "add", "origin", URL)
        self.common = ["--repo", str(self.repo), "--remote", "origin", "--expected-fetch-url", URL, "--expected-push-url", URL, "--token-file", str(self.token)]

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def git(self, *args):
        return subprocess.run(["git", *args], env=self.env, check=True, text=True, capture_output=True)

    def run_helper(self, *args, extra=None, input=None):
        # Exercise executable startup, not just bash sourcing/interpreting it.
        result = subprocess.run([str(HELPER), *args], env={**self.env, **(extra or {})}, input=input, text=True, capture_output=True, timeout=10)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        self.assertEqual(self.server.errors, [])
        return result

    def push(self, **kwargs):
        return self.run_helper("git-push", *self.common, "--refspec", ":refs/heads/probe", **kwargs)

    def rest(self, *args, **kwargs):
        return self.run_helper("rest", "--token-file", str(self.token), "--method", "POST", "--url", "https://git.ablz.au/api/v1/repos/x/y/issues", *args, **kwargs)

    def test_global_and_system_trace2_artifacts_do_not_contain_credentials(self):
        for scope in ("GLOBAL", "SYSTEM"):
            with self.subTest(scope=scope):
                trace = self.root / (scope + ".trace")
                config = self.root / (scope + ".config")
                config.write_text(f"[trace2]\n eventTarget = {trace}\n normalTarget = {trace}.normal\n perfTarget = {trace}.perf\n envVars = GIT_CONFIG_VALUE_0\n configParams = http.*.extraheader\n")
                result = self.push(extra={"GIT_CONFIG_" + scope: str(config), "GIT_CONFIG_NOSYSTEM": "0"})
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.server.requests)
                self.assertEqual(self.server.requests[-1][1], "token " + TOKEN.lower())
                for artifact in self.root.glob(scope + ".trace*"):
                    self.assertNotIn(TOKEN, artifact.read_text())

    def test_inherited_rewrites_are_removed_before_validation(self):
        wrong = "https://git.ablz.au/abl030/other.git"
        self.git("-C", str(self.repo), "remote", "set-url", "origin", wrong)
        for extra in (
            {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "url." + URL + ".insteadOf", "GIT_CONFIG_VALUE_0": wrong},
            {"GIT_CONFIG_PARAMETERS": "'url." + URL + ".insteadOf=" + wrong + "'"},
        ):
            result = self.push(extra=extra)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("fetch URL set", result.stderr)
            self.assertEqual(self.server.requests, [])

    def test_real_curlrc_is_disabled(self):
        trace = self.root / "curl.trace"
        (self.root / ".curlrc").write_text(f"verbose\ntrace-ascii = {trace}\n")
        self.assertEqual(self.rest().returncode, 0)
        self.assertFalse(trace.exists())

    def test_literal_and_stdin_json_and_at_file_rejection(self):
        for args, input, expected in ((["--body", '{"body":"literal"}'], None, b'{"body":"literal"}'), (["--body-stdin"], '{"body":"stdin"}\n', b'{"body":"stdin"}')):
            result = self.rest(*args, input=input)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.server.requests[-1][2], expected)
        self.server.requests.clear()
        result = self.rest("--body", "@" + str(self.token))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.server.requests, [])

    def test_git_and_rest_reject_redirects(self):
        self.server.mode = "redirect"
        for run in (self.push, self.rest):
            self.server.requests.clear()
            self.assertNotEqual(run().returncode, 0)
            self.assertEqual(len(self.server.requests), 1)

    def test_url_scoped_config_cannot_enable_push_or_readback_redirects(self):
        # Git matches HTTP configuration by URL specificity, before command
        # scope precedence. Exercise both equal and distinct fetch/push URLs.
        config = self.root / "global.gitconfig"
        self.env["GIT_CONFIG_GLOBAL"] = str(config)
        self.server.mode = "same-origin-redirect"
        for push_url in (URL, "https://git.ablz.au/abl030/push-target.git"):
            self.git("-C", str(self.repo), "config", "remote.origin.pushurl", push_url)
            self.common[self.common.index("--expected-push-url") + 1] = push_url
            for scopes in (("https://git.ablz.au/",), ("https://git.ablz.au/abl030/",), (URL, push_url), (URL + "/", push_url + "/")):
                config.write_text("".join(f'[http "{scope}"]\n followRedirects = true\n' for scope in scopes))
                for command in ("git-push", "git-ls-remote"):
                    with self.subTest(push_url=push_url, scopes=scopes, command=command):
                        self.server.requests.clear()
                        args = ("--refspec", ":refs/heads/probe") if command == "git-push" else ("--ref", "refs/heads/snapshots")
                        result = self.run_helper(command, *self.common, *args)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(len(self.server.requests), 1, self.server.requests)
                        request, auth, _ = self.server.requests[0]
                        self.assertNotIn("/other.git/", request)
                        self.assertEqual(auth, "token " + TOKEN.lower())

    def test_private_readback_uses_short_lived_authentication(self):
        self.server.mode = "private"
        anonymous = subprocess.run(["git", "-C", str(self.repo), "ls-remote", "origin", "refs/heads/snapshots"], env=self.env, capture_output=True)
        self.assertNotEqual(anonymous.returncode, 0)
        self.server.requests.clear()
        startup = self.root / "bash-env"
        startup.write_text("trap 'set -x' DEBUG\n")
        result = self.run_helper("git-ls-remote", *self.common, "--ref", "refs/heads/snapshots", extra={"BASH_ENV": str(startup)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, SHA + "\trefs/heads/snapshots\n")
        self.assertTrue(all(auth == "token " + TOKEN.lower() for _, auth, _ in self.server.requests))

    def test_callers_own_exact_sha_comparison_and_fail_closed(self):
        root = Path(__file__).parents[2]
        updater = Path(os.environ.get("RFU_SOURCE", root / "scripts/rolling_flake_update.sh")).read_text()
        snapshot = Path(os.environ.get("SNAPSHOT_SOURCE", root / "hermes/skills/homelab-agents/brain-backup/scripts/brain-snapshot.sh")).read_text()
        updater_body = "verify_remote_push() {" + updater.split("verify_remote_push() {", 1)[1].split("\n}\n", 1)[0] + "\n}\nverify_remote_push\n"
        snapshot_body = "remote_commit=$(" + snapshot.split("remote_commit=$(", 1)[1].split('\nnote "pushed encrypted snapshot:', 1)[0]
        setup = '''set -euo pipefail
git() { printf '%s\\n' "$EXPECTED_SHA"; }
log() { :; }
die() { exit 1; }
commit="$EXPECTED_SHA"
'''
        for caller, body in (("updater", updater_body), ("snapshot", snapshot_body)):
            for case, expected, mode in (("matching", SHA, "private"), ("mismatch", "b" * 40, "private"), ("missing", SHA, "private-empty"), ("transport-failure", SHA, "normal")):
                with self.subTest(caller=caller, case=case):
                    self.server.mode = mode
                    env = {**self.env, "FORGEJO_AUTH_HELPER": str(HELPER), "FORGEJO_AUTH": str(HELPER), "REMOTE_URL": URL, "REMOTE": URL, "PUSH_TOKEN_FILE": str(self.token), "TOKEN_FILE": str(self.token), "repo": str(self.repo), "EXPECTED_SHA": expected, "BRANCH": "snapshots"}
                    result = subprocess.run(["bash", "-c", setup + body], cwd=self.repo, env=env, text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode == 0, case == "matching", result.stderr)
                    self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_empty_second_push_url_is_rejected(self):
        self.git("-C", str(self.repo), "config", "--add", "remote.origin.pushurl", URL)
        self.git("-C", str(self.repo), "config", "--add", "remote.origin.pushurl", "")
        self.assertEqual(self.push().returncode, 2)
        self.assertEqual(self.server.requests, [])


if __name__ == "__main__":
    unittest.main()
