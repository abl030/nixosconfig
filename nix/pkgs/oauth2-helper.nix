# OAuth2 helper for mbsync — refresh tokens at sync time, plus a one-time
# device-code bootstrap subcommand.
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


  def o365_endpoints(tenant):
      base = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0"
      return base + "/devicecode", base + "/token"


  def gmail_endpoints():
      return ("https://oauth2.googleapis.com/device/code",
              "https://oauth2.googleapis.com/token")


  def http_post(url, params, timeout=30):
      body = urllib.parse.urlencode(params).encode()
      req = urllib.request.Request(url, data=body, method="POST")
      req.add_header("Content-Type", "application/x-www-form-urlencoded")
      with urllib.request.urlopen(req, timeout=timeout) as r:
          return json.loads(r.read())


  def die(msg, code=1):
      sys.stderr.write(f"oauth2-helper: {msg}\n")
      raise SystemExit(code)


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
          _, token_url = gmail_endpoints()
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
      provider = args.provider
      user = args.user

      if provider == "o365":
          client_id = args.client_id or THUNDERBIRD_O365_CLIENT_ID
          client_secret = None
          tenant = args.tenant or "common"
          device_url, token_url = o365_endpoints(tenant)
          scope = O365_SCOPE
      else:  # gmail
          if not args.client_id or not args.client_secret:
              die("gmail bootstrap requires --client-id and --client-secret")
          client_id = args.client_id
          client_secret = args.client_secret
          tenant = None
          device_url, token_url = gmail_endpoints()
          scope = GMAIL_SCOPE

      dc_params = {"client_id": client_id, "scope": scope}
      if provider == "o365":
          dc_params["login_hint"] = user

      try:
          dc = http_post(device_url, dc_params)
      except urllib.error.HTTPError as e:
          body = e.read().decode("utf-8", errors="replace")
          die(f"device-code request failed: HTTP {e.code}: {body}")
      except Exception as e:
          die(f"device-code request failed: {e}")

      user_code = dc.get("user_code")
      verify_uri = dc.get("verification_uri") or dc.get("verification_url")
      device_code = dc.get("device_code")
      interval = int(dc.get("interval", 5))
      expires_in = int(dc.get("expires_in", 900))

      sys.stderr.write(
          f"\n  Sign in at: {verify_uri}\n"
          f"  Code:       {user_code}\n"
          f"  Account:    {user}\n\n"
          f"Polling every {interval}s; code expires in {expires_in}s.\n"
      )

      poll_params = {
          "client_id": client_id,
          "device_code": device_code,
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

          # paste-ready dotenv block on stdout
          print(f"OAUTH_PROVIDER={provider}")
          print(f"OAUTH_CLIENT_ID={client_id}")
          if client_secret:
              print(f"OAUTH_CLIENT_SECRET={client_secret}")
          if tenant and tenant != "common":
              print(f"OAUTH_TENANT={tenant}")
          print(f"OAUTH_REFRESH_TOKEN={refresh}")
          sys.stderr.write(
              "\nDone. Paste the block above into:\n"
              "  secrets/hosts/<host>/mailarchive-<account>.env\n"
              "and re-encrypt with `sops -e -i <path>`.\n"
          )
          return

      die("device code expired before sign-in completed")


  def main():
      p = argparse.ArgumentParser(description="OAuth2 helper for mbsync (Gmail / O365)")
      sub = p.add_subparsers(dest="cmd", required=True)

      pr = sub.add_parser("refresh", help="Print a fresh access token (used by mbsync PassCmd)")
      pr.add_argument("--provider", choices=["gmail", "o365"],
                      help="Provider (defaults to OAUTH_PROVIDER env)")

      pb = sub.add_parser("bootstrap", help="One-time interactive device-code flow")
      pb.add_argument("--provider", choices=["gmail", "o365"], required=True)
      pb.add_argument("--user", required=True, help="Email address (login_hint for o365)")
      pb.add_argument("--client-id", default=None,
                      help="OAuth client ID (defaults to Thunderbird's id for o365)")
      pb.add_argument("--client-secret", default=None,
                      help="OAuth client secret (required for gmail)")
      pb.add_argument("--tenant", default=None,
                      help="O365 tenant (default: common)")

      args = p.parse_args()
      if args.cmd == "refresh":
          cmd_refresh(args)
      elif args.cmd == "bootstrap":
          cmd_bootstrap(args)


  if __name__ == "__main__":
      main()
''
