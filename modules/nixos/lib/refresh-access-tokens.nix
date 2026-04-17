# Shared derivation: validate the GitHub PAT extracted from nix-netrc and
# (re)write /run/secrets/nix-access-tokens. Invoked from both:
#
#   - base.nix activation script (runs on every switch + on boot)
#   - update.nix nixos-upgrade.service ExecStartPre (runs right before the
#     flake fetch, so a stale PAT is cleared before it can poison fetches)
#
# Invalidation policy: ONLY a definitive 401/403 from api.github.com causes
# us to blank the file. Network / DNS / timeout errors preserve the token
# (the worst case is a legitimate token with a flaky network).
#
# See issue #210 for the incident that motivated this.
{pkgs}:
pkgs.writeShellScript "refresh-nix-access-tokens" ''
  set -u
  token=$(${pkgs.gawk}/bin/awk '/machine github\.com/{found=1} found && /password/{print $2; exit}' /run/secrets/nix-netrc 2>/dev/null || true)

  write_empty() {
    : > /run/secrets/nix-access-tokens
    chmod 444 /run/secrets/nix-access-tokens
  }
  write_token() {
    printf 'access-tokens = github.com=%s\n' "$1" > /run/secrets/nix-access-tokens
    chmod 444 /run/secrets/nix-access-tokens
  }

  if [ -z "$token" ]; then
    write_empty
    exit 0
  fi

  http_code=$(${pkgs.curl}/bin/curl -sS -o /dev/null -w '%{http_code}' \
                --max-time 5 \
                -H "Authorization: Bearer $token" \
                https://api.github.com/user 2>/dev/null || echo "000")
  if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
    echo "[nix-access-tokens] GitHub rejected PAT (HTTP $http_code); writing empty access-tokens to avoid poisoning public fetches" >&2
    write_empty
  else
    write_token "$token"
  fi
''
