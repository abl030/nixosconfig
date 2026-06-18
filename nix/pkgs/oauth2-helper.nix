# OAuth2 helper for mbsync — refresh tokens at sync time, plus a one-time
# interactive bootstrap subcommand.
#
# Bootstrap flows differ by provider (each uses the one its IMAP scope allows):
#   - o365  → device-code flow (Microsoft permits the IMAP scope there).
#   - gmail → installed-app AUTHORIZATION-CODE flow over a localhost loopback.
#     Gmail's restricted scope https://mail.google.com/ is NOT on Google's
#     device-flow allowlist ("Invalid device flow scope"), so the device flow
#     cannot be used for Gmail. Requires a Desktop-app OAuth client + a local
#     listener for the redirect. See docs/wiki/services/mailarchive.md.
#
# The `refresh` path (used by mbsync PassCmd) is a plain refresh_token grant
# and is identical regardless of how the refresh token was first obtained.
#
# Used by:
# - modules/nixos/services/mailarchive.nix  (mbsync PassCmd → `oauth2-helper refresh`)
# - nix/devshell.nix                         (apps.oauth2-helper for `nix run`)
#
# Runbook: docs/wiki/services/mailarchive.md
{pkgs}:
pkgs.writers.writePython3Bin "oauth2-helper" {
  flakeIgnore = ["E501" "E402"];
} ''
  """OAuth2 helper for mbsync — refresh + bootstrap for Gmail and O365."""

  import argparse
  import base64
  import hashlib
  import http.server
  import json
  import os
  import sys
  import time
  import urllib.error
  import urllib.parse
  import urllib.request

  THUNDERBIRD_O365_CLIENT_ID = "9e5f94bc-e8a4-4e73-b8be-63364c29d753"
  O365_SCOPE = "offline_access https://outlook.office.com/IMAP.AccessAsUser.All"
  GMAIL_SCOPE = "https://mail.google.com/"
  GMAIL_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
  GMAIL_TOKEN_URL = "https://oauth2.googleapis.com/token"


  def o365_endpoints(tenant):
      base = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0"
      return base + "/devicecode", base + "/token"


  def http_post(url, params, timeout=30):
      body = urllib.parse.urlencode(params).encode()
      req = urllib.request.Request(url, data=body, method="POST")
      req.add_header("Content-Type", "application/x-www-form-urlencoded")
      with urllib.request.urlopen(req, timeout=timeout) as r:
          return json.loads(r.read())


  def die(msg, code=1):
      sys.stderr.write(f"oauth2-helper: {msg}\n")
      raise SystemExit(code)


  def emit_dotenv(provider, client_id, client_secret, tenant, refresh):
      """Print a paste-ready dotenv block on stdout (token goes here)."""
      print(f"OAUTH_PROVIDER={provider}")
      print(f"OAUTH_CLIENT_ID={client_id}")
      if client_secret:
          print(f"OAUTH_CLIENT_SECRET={client_secret}")
      if tenant and tenant != "common":
          print(f"OAUTH_TENANT={tenant}")
      print(f"OAUTH_REFRESH_TOKEN={refresh}")
      sys.stderr.write(
          "\nDone. Redirect the stdout block into the secret file, then encrypt:\n"
          "  ( cd secrets && sops -e -i hosts/<host>/mailarchive-<account>.env )\n"
      )


  def cmd_refresh(args):
      provider = os.environ.get("OAUTH_PROVIDER") or args.provider
      if provider not in ("o365", "gmail"):
          die("provider must be set via --provider or OAUTH_PROVIDER (o365|gmail)")
      refresh = os.environ.get("OAUTH_REFRESH_TOKEN")
      if not refresh:
          die("OAUTH_REFRESH_TOKEN not set")
      client_id = os.environ.get("OAUTH_CLIENT_ID")
      if not client_id:
          if provider == "o365":
              client_id = THUNDERBIRD_O365_CLIENT_ID
          else:
              die("OAUTH_CLIENT_ID not set (required for gmail)")
      client_secret = os.environ.get("OAUTH_CLIENT_SECRET")
      tenant = os.environ.get("OAUTH_TENANT") or "common"

      if provider == "o365":
          _, token_url = o365_endpoints(tenant)
          params = {
              "client_id": client_id,
              "grant_type": "refresh_token",
              "refresh_token": refresh,
              "scope": O365_SCOPE,
          }
      else:  # gmail
          if not client_secret:
              die("OAUTH_CLIENT_SECRET not set (required for gmail)")
          token_url = GMAIL_TOKEN_URL
          params = {
              "client_id": client_id,
              "client_secret": client_secret,
              "grant_type": "refresh_token",
              "refresh_token": refresh,
          }

      try:
          result = http_post(token_url, params)
      except urllib.error.HTTPError as e:
          body = e.read().decode("utf-8", errors="replace")
          die(f"HTTP {e.code} from token endpoint: {body}")
      except Exception as e:
          die(f"refresh failed: {e}")

      access = result.get("access_token")
      if not access:
          die(f"no access_token in response: {json.dumps(result)}")
      print(access)


  def cmd_bootstrap(args):
      if args.provider == "o365":
          bootstrap_o365(args)
      else:
          bootstrap_gmail(args)


  def bootstrap_o365(args):
      user = args.user
      client_id = args.client_id or THUNDERBIRD_O365_CLIENT_ID
      client_secret = args.client_secret
      tenant = args.tenant or "common"
      device_url, token_url = o365_endpoints(tenant)

      try:
          dc = http_post(device_url, {"client_id": client_id, "scope": O365_SCOPE, "login_hint": user})
      except urllib.error.HTTPError as e:
          body = e.read().decode("utf-8", errors="replace")
          die(f"device-code request failed: HTTP {e.code}: {body}")
      except Exception as e:
          die(f"device-code request failed: {e}")

      verify_uri = dc.get("verification_uri") or dc.get("verification_url")
      interval = int(dc.get("interval", 5))
      expires_in = int(dc.get("expires_in", 900))

      sys.stderr.write(
          f"\n  Sign in at: {verify_uri}\n"
          f"  Code:       {dc.get('user_code')}\n"
          f"  Account:    {user}\n\n"
          f"Polling every {interval}s; code expires in {expires_in}s.\n"
      )

      poll_params = {
          "client_id": client_id,
          "device_code": dc.get("device_code"),
          "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
      }
      if client_secret:
          poll_params["client_secret"] = client_secret

      deadline = time.time() + expires_in
      while time.time() < deadline:
          time.sleep(interval)
          try:
              r = http_post(token_url, poll_params)
          except urllib.error.HTTPError as e:
              try:
                  body = json.loads(e.read())
              except Exception:
                  body = {}
              err = body.get("error", "")
              if err == "authorization_pending":
                  continue
              if err == "slow_down":
                  interval += 5
                  continue
              die(f"token endpoint error: {body}")
          except Exception as e:
              die(f"poll failed: {e}")

          if "access_token" not in r:
              die(f"unexpected response: {json.dumps(r)}")
          refresh = r.get("refresh_token")
          if not refresh:
              die("token endpoint returned no refresh_token (offline_access scope missing?)")
          emit_dotenv("o365", client_id, client_secret, tenant, refresh)
          return

      die("device code expired before sign-in completed")


  def extract_auth_code(pasted):
      """Pull the auth code from a pasted bare code or a full redirect URL."""
      pasted = pasted.strip()
      if "code=" in pasted:
          return urllib.parse.unquote(pasted.split("code=", 1)[1].split("&", 1)[0])
      return pasted


  def gmail_listen_for_code(auth_url, user, redirect_uri, port):
      """Run a local HTTP listener and catch the redirect carrying the code."""
      holder = {}

      class Handler(http.server.BaseHTTPRequestHandler):
          def log_message(self, *_a):
              return

          def do_GET(self):
              params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
              if "code" in params:
                  holder["code"] = params["code"][0]
                  msg = "Authorization received - you can close this tab and return to the terminal."
              elif "error" in params:
                  holder["error"] = params["error"][0]
                  msg = "Authorization failed - check the terminal."
              else:
                  msg = "Waiting for the authorization redirect..."
              body = ("<html><body><h2>" + msg + "</h2></body></html>").encode("utf-8")
              self.send_response(200)
              self.send_header("Content-Type", "text/html; charset=utf-8")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

      try:
          srv = http.server.HTTPServer(("127.0.0.1", port), Handler)
      except OSError as e:
          die(f"cannot bind {redirect_uri}: {e} (try --port, or use --manual)")

      sys.stderr.write(
          f"\n  Open this URL in a browser ON THIS MACHINE\n"
          f"  (or SSH-forward the port first: ssh -L {port}:127.0.0.1:{port} <thishost>):\n\n"
          f"    {auth_url}\n\n"
          f"  Account: {user}\n"
          f"  Click through the unverified-app screen: Advanced -> Go to ... (unsafe).\n"
          f"  Listening on {redirect_uri} for the redirect (Ctrl-C to abort)...\n"
      )

      while "code" not in holder and "error" not in holder:
          srv.handle_request()
      srv.server_close()

      if "error" in holder:
          die(f"authorization failed: {holder['error']}")
      return holder["code"]


  def gmail_manual_code(auth_url, user):
      """Print the URL; read the auth code back by paste (headless/SSH/WSL)."""
      sys.stderr.write(
          f"\n  Open this URL in ANY browser:\n\n    {auth_url}\n\n"
          f"  Account: {user}\n"
          f"  Click through the unverified-app screen (Advanced -> Go to ... (unsafe)), then Allow.\n"
          f"  Your browser will then try to load a http://127.0.0.1:... page and FAIL to connect -\n"
          f"  that is expected. Copy the whole address-bar URL (or just the code= value) and paste\n"
          f"  it below.\n\n"
          f"  Paste redirect URL or code, then Enter:\n  > "
      )
      sys.stderr.flush()
      pasted = sys.stdin.readline()
      code = extract_auth_code(pasted)
      if not code:
          die("no auth code parsed from input (run --manual on a terminal, not a pipe)")
      return code


  def bootstrap_gmail(args):
      # Gmail's restricted scope is rejected by the device-code flow, so this is
      # the installed-app authorization-code flow over a loopback redirect.
      # Default: a local listener catches the redirect. --manual: print the URL
      # and read the code back by paste — works headless / over SSH / on WSL,
      # where the browser cannot reach the helper's 127.0.0.1 listener.
      user = args.user
      if not args.client_id or not args.client_secret:
          die("gmail bootstrap requires --client-id and --client-secret (a Desktop-app OAuth client)")
      client_id = args.client_id
      client_secret = args.client_secret
      port = args.port
      redirect_uri = f"http://127.0.0.1:{port}"

      # PKCE (S256): verifier is unreserved-charset, 43-128 chars.
      verifier = base64.urlsafe_b64encode(os.urandom(64)).rstrip(b"=").decode("ascii")
      challenge = base64.urlsafe_b64encode(
          hashlib.sha256(verifier.encode("ascii")).digest()
      ).rstrip(b"=").decode("ascii")

      auth_url = GMAIL_AUTH_URL + "?" + urllib.parse.urlencode({
          "client_id": client_id,
          "redirect_uri": redirect_uri,
          "response_type": "code",
          "scope": GMAIL_SCOPE,
          "access_type": "offline",
          "prompt": "consent",
          "login_hint": user,
          "code_challenge": challenge,
          "code_challenge_method": "S256",
      })

      if args.manual:
          code = gmail_manual_code(auth_url, user)
      else:
          code = gmail_listen_for_code(auth_url, user, redirect_uri, port)

      try:
          r = http_post(GMAIL_TOKEN_URL, {
              "code": code,
              "client_id": client_id,
              "client_secret": client_secret,
              "redirect_uri": redirect_uri,
              "grant_type": "authorization_code",
              "code_verifier": verifier,
          })
      except urllib.error.HTTPError as e:
          body = e.read().decode("utf-8", errors="replace")
          die(f"token exchange failed: HTTP {e.code}: {body}")
      except Exception as e:
          die(f"token exchange failed: {e}")

      refresh = r.get("refresh_token")
      if not refresh:
          die("no refresh_token returned - ensure the app is PUBLISHED to Production "
              "and you completed consent (access_type=offline + prompt=consent were sent)")
      emit_dotenv("gmail", client_id, client_secret, None, refresh)


  def main():
      p = argparse.ArgumentParser(description="OAuth2 helper for mbsync (Gmail / O365)")
      sub = p.add_subparsers(dest="cmd", required=True)

      pr = sub.add_parser("refresh", help="Print a fresh access token (used by mbsync PassCmd)")
      pr.add_argument("--provider", choices=["gmail", "o365"],
                      help="Provider (defaults to OAUTH_PROVIDER env)")

      pb = sub.add_parser("bootstrap",
                          help="One-time bootstrap (o365=device-code, gmail=loopback auth-code)")
      pb.add_argument("--provider", choices=["gmail", "o365"], required=True)
      pb.add_argument("--user", required=True, help="Email address (login_hint)")
      pb.add_argument("--client-id", default=None,
                      help="OAuth client ID (defaults to Thunderbird's id for o365)")
      pb.add_argument("--client-secret", default=None,
                      help="OAuth client secret (required for the gmail Desktop-app client)")
      pb.add_argument("--tenant", default=None, help="O365 tenant (default: common)")
      pb.add_argument("--port", type=int, default=8087,
                      help="Loopback port for the gmail authorization-code redirect")
      pb.add_argument("--manual", action="store_true",
                      help="Gmail: print the URL and paste the code back (no listener; for headless/SSH/WSL)")

      args = p.parse_args()
      if args.cmd == "refresh":
          cmd_refresh(args)
      elif args.cmd == "bootstrap":
          cmd_bootstrap(args)


  if __name__ == "__main__":
      main()
''
