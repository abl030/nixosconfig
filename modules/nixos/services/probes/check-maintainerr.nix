{pkgs}:
pkgs.writeShellApplication {
  name = "check-maintainerr";
  runtimeInputs = [pkgs.curl pkgs.podman];
  text = ''
    port=$1
    # Retry for up to a minute: a rebuild can start this probe while the
    # container is still coming back up after a restart.
    curl --fail --silent --show-error --max-time 5 \
      --retry 30 --retry-delay 2 --retry-max-time 60 --retry-all-errors \
      "http://127.0.0.1:$port/api/health/ready" >/dev/null

    # Exercise the bind mount as the same uid:gid as the application without
    # changing Maintainerr's database or user-owned configuration.
    podman exec --user 2025:2025 maintainerr sh -c \
      "set -eu; p=\$(mktemp /opt/data/.homelab-probe.XXXXXX); trap 'rm -f \"\$p\"' EXIT; printf probe > \"\$p\"; test \"\$(cat \"\$p\")\" = probe"
  '';
}
