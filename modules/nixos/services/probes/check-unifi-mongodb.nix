# Deep write-path probe for the UniFi MongoDB container.
#
# Authenticates as the UniFi *application* role (not root) and round-trips a
# real write against the primary UniFi database: insert a probe document,
# read it back, delete it. That is the failure class the shallow
# "https://unifi.ablz.au/" Kuma monitor cannot see — the UI answers 200 while
# the database underneath is unwritable:
#
#   - dbpath ownership drifted off the fixed UID (permission denied)
#   - the virtiofs dataset filled up (no space left on device)
#   - the application role lost its dbOwner grants, or its password rotated
#     out from under system.properties
#   - mongod is up but wedged / not accepting writes
#
# See the "Deep write-path probes" section of
# docs/wiki/nixos-service-modules.md for the pattern, and
# docs/wiki/services/unifi-controller.md for this service's model.
#
# Auth: credentials are read from files (UNIFI_MONGO_USER_FILE /
# UNIFI_MONGO_PASSWORD_FILE, the sops-managed 0400 secrets) and handed to
# mongosh over STDIN. They never appear in argv — `podman exec` argv is
# readable by anyone who can run `podman inspect` — and never in the unit
# environment, where `systemctl show` would print them.
#
# Exit codes:
#   0 → write path healthy → push UP to Kuma
#   1 → mongod unreachable, auth failed, or the write round-trip failed
#   2 → environment/secret missing or malformed (probe cannot run)
{pkgs}:
pkgs.writeShellApplication {
  name = "check-unifi-mongodb";
  runtimeInputs = with pkgs; [coreutils];
  text = ''
    set -uo pipefail

    container="''${UNIFI_MONGO_CONTAINER:-unifi-mongodb}"
    db="''${UNIFI_MONGO_DB:-unifi}"
    podman="''${UNIFI_MONGO_PODMAN:-podman}"
    user_file="''${UNIFI_MONGO_USER_FILE:?UNIFI_MONGO_USER_FILE not set}"
    pwd_file="''${UNIFI_MONGO_PASSWORD_FILE:?UNIFI_MONGO_PASSWORD_FILE not set}"

    for f in "$user_file" "$pwd_file"; do
      if [ ! -r "$f" ]; then
        echo "[probe] credential file unreadable: $f" >&2
        exit 2
      fi
    done

    user="$(cat "$user_file")"
    pass="$(cat "$pwd_file")"

    # The credentials are alphanumeric by construction (see the module), which
    # is what lets them be embedded in the JS below without escaping. Assert it
    # rather than assume it: a hand-rotated password with a quote in it would
    # otherwise produce a confusing syntax error instead of a clear failure.
    for pair in "username:$user" "password:$pass"; do
      label="''${pair%%:*}"
      value="''${pair#*:}"
      case "$value" in
        "")
          echo "[probe] empty $label in credential file" >&2
          exit 2
          ;;
        *[!A-Za-z0-9]*)
          echo "[probe] $label contains characters outside [A-Za-z0-9]" >&2
          exit 2
          ;;
      esac
    done

    # Insert → read back → delete, all as the application role. `quit(n)` sets
    # mongosh's exit status, so any thrown error or failed assertion becomes a
    # non-zero exit and Kuma misses its heartbeat.
    if ! "$podman" exec -i "$container" mongosh --quiet --norc \
      >/tmp/check-unifi-mongodb.out 2>&1 <<EOF
    try {
      var admin = db.getSiblingDB("admin");
      admin.auth("$user", "$pass");
    } catch (e) {
      print("[probe] authentication failed: " + e.message);
      quit(1);
    }
    try {
      var target = db.getSiblingDB("$db");
      var marker = "homelab-deep-probe";
      var doc = { _id: marker, checkedAt: new Date() };
      target._homelab_probe.replaceOne({ _id: marker }, doc, { upsert: true });
      var found = target._homelab_probe.findOne({ _id: marker });
      if (found === null) {
        print("[probe] probe document was not readable after write");
        quit(1);
      }
      target._homelab_probe.deleteOne({ _id: marker });
    } catch (e) {
      print("[probe] write round-trip failed: " + e.message);
      quit(1);
    }
    quit(0);
    EOF
    then
      echo "[probe] MongoDB write-path check failed:" >&2
      cat /tmp/check-unifi-mongodb.out >&2
      rm -f /tmp/check-unifi-mongodb.out
      exit 1
    fi

    rm -f /tmp/check-unifi-mongodb.out
    exit 0
  '';
}
