# shellcheck shell=bash
# shellcheck disable=SC2154 # callers set these unexported credential variables
{ set +x; } 2>/dev/null
# Feed curl's Basic-auth config over stdin so credentials never enter argv.
# Callers set the unexported shell variables kopia_auth_user/pass, then invoke
# `kopia_curl` with ordinary curl options and URL arguments.
kopia_curl() {
  local escaped_user escaped_pass
  if [[ "$kopia_auth_user$kopia_auth_pass" =~ [[:cntrl:]] ]]; then
    echo "Kopia HTTP credentials must not contain control characters" >&2
    return 2
  fi
  escaped_user=${kopia_auth_user//\\/\\\\}
  escaped_user=${escaped_user//\"/\\\"}
  escaped_pass=${kopia_auth_pass//\\/\\\\}
  escaped_pass=${escaped_pass//\"/\\\"}
  printf 'user = "%s:%s"\n' "$escaped_user" "$escaped_pass" \
    | "$kopia_curl_bin" --config - "$@"
}
