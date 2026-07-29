#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # intentional isolated xtrace subshell
set -euo pipefail

helper=${1:?helper path required}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '#!%s\n' "$(command -v bash)" >"$tmp/fake-curl"
cat >>"$tmp/fake-curl" <<'EOF'
set -euo pipefail
printf '%s\0' "$@" >"$KOPIA_TEST_ARGV"
cat >"$KOPIA_TEST_STDIN"
EOF
chmod +x "$tmp/fake-curl"

(
  set -x
  # shellcheck source=modules/nixos/services/probes/kopia-curl-auth.sh
  source "$helper"
  kopia_auth_user='trace-user'
  kopia_auth_pass='trace-secret-sentinel'
  kopia_curl_bin="$tmp/fake-curl"
  export KOPIA_TEST_ARGV="$tmp/trace-argv" KOPIA_TEST_STDIN="$tmp/trace-stdin"
  kopia_curl https://example.invalid
) 2>"$tmp/trace"
if grep -F 'trace-secret-sentinel' "$tmp/trace"; then
  echo "Kopia password leaked through inherited xtrace" >&2
  exit 1
fi

# shellcheck source=modules/nixos/services/probes/kopia-curl-auth.sh
source "$helper"
kopia_auth_user='fixture-user'
kopia_auth_pass='fixture-password-with-"quote"-and-\slash'
kopia_curl_bin="$tmp/fake-curl"
export KOPIA_TEST_ARGV="$tmp/argv" KOPIA_TEST_STDIN="$tmp/stdin"

kopia_curl -fsS https://example.invalid/api/v1/sources

if grep -aF 'fixture-password' "$tmp/argv"; then
  echo "Kopia password leaked into curl argv" >&2
  exit 1
fi
grep -aF -- '--config' "$tmp/argv" >/dev/null
grep -F 'user = "fixture-user:fixture-password-with-\"quote\"-and-\\slash"' "$tmp/stdin" >/dev/null

rm -f "$tmp/argv" "$tmp/stdin"
kopia_auth_pass=$'invalid\nuser = "injected"'
if kopia_curl https://example.invalid 2>/dev/null; then
  echo "newline-bearing credentials must be rejected" >&2
  exit 1
fi
test ! -e "$tmp/argv"

kopia_auth_pass=$'invalid\tuser = "injected"'
if kopia_curl https://example.invalid 2>/dev/null; then
  echo "control-character credentials must be rejected" >&2
  exit 1
fi
test ! -e "$tmp/argv"
