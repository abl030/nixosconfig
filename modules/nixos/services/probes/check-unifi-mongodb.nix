# UniFi MongoDB write-path probe.
#
# This probes the native MongoDB service directly. It deliberately performs a
# real insert/read/delete as the application role so it catches:
#   - mongodb.service being down or bound incorrectly;
#   - dbpath permission/read-only/disk-full failures;
#   - application-role password or grant drift.
#
# Credentials are read from files and the mongosh program receives its script on
# STDIN. They never appear in argv or in the probe service environment.
{pkgs}:
pkgs.writeShellApplication {
  name = "check-unifi-mongodb";
  runtimeInputs = with pkgs; [coreutils gnugrep];
  text = ''
    set -uo pipefail

    host="''${UNIFI_MONGO_HOST:-127.0.0.1}"
    port="''${UNIFI_MONGO_PORT:-27117}"
    db="''${UNIFI_MONGO_DB:-ace}"
    collection="''${UNIFI_MONGO_COLLECTION:-_homelab_probe}"
    mongosh="''${UNIFI_MONGO_MONGOSH:-mongosh}"
    user_file="''${UNIFI_MONGO_USER_FILE:?UNIFI_MONGO_USER_FILE not set}"
    pwd_file="''${UNIFI_MONGO_PASSWORD_FILE:?UNIFI_MONGO_PASSWORD_FILE not set}"

    case "$host" in
      127.0.0.1) ;;
      *) echo "unifi-mongodb-probe: refusing non-loopback host" >&2; exit 2 ;;
    esac
    case "$port" in
      ""|*[!0-9]*) echo "unifi-mongodb-probe: malformed port" >&2; exit 2 ;;
    esac
    case "$db" in
      ""|*[!A-Za-z0-9_]*) echo "unifi-mongodb-probe: malformed database name" >&2; exit 2 ;;
    esac
    case "$collection" in
      ""|*[!A-Za-z0-9_]*) echo "unifi-mongodb-probe: malformed collection name" >&2; exit 2 ;;
    esac

    if [ ! -r "$user_file" ] || [ ! -r "$pwd_file" ]; then
      echo "unifi-mongodb-probe: application credential file is missing or unreadable" >&2
      exit 2
    fi

    user="$(cat "$user_file")"
    pass="$(cat "$pwd_file")"
    case "$user" in
      ""|*[!A-Za-z0-9]*) echo "unifi-mongodb-probe: malformed application username" >&2; exit 2 ;;
    esac
    case "$pass" in
      ""|*[!A-Za-z0-9]*) echo "unifi-mongodb-probe: malformed application password" >&2; exit 2 ;;
    esac

    out="$(mktemp)"
    # shellcheck disable=SC2064  # $out is expanded now on purpose
    trap "rm -f '$out'" EXIT

    if ! timeout 30s "$mongosh" --quiet --norc --host "$host" --port "$port" --file /dev/stdin >"$out" 2>&1 <<EOF
    (function () {
      try {
        if (!db.getSiblingDB("admin").auth("$user", "$pass")) {
          print("application authentication returned false");
          quit(11);
        }
        var collection = db.getSiblingDB("$db").getCollection("$collection");
        var id = new ObjectId();
        var inserted = collection.insertOne({ _id: id, probe: "unifi-mongodb" });
        if (inserted.acknowledged !== true) {
          print("probe insert was not acknowledged");
          quit(12);
        }
        if (collection.findOne({ _id: id }) === null) {
          print("probe read did not find the inserted document");
          quit(13);
        }
        if (collection.deleteOne({ _id: id }).deletedCount !== 1) {
          print("probe delete did not remove the inserted document");
          quit(14);
        }
        print("UNIFI_MONGO_PROBE_OK");
      } catch (e) {
        print("application write-path failed: " + e.message);
        quit(15);
      }
      quit(0);
    })()
    EOF
    then
      detail="$(cat "$out")"
      detail="''${detail//"$user"/<redacted>}"
      detail="''${detail//"$pass"/<redacted>}"
      echo "unifi-mongodb-probe: mongosh failed: $detail" >&2
      exit 1
    fi

    if ! grep -qF UNIFI_MONGO_PROBE_OK "$out"; then
      detail="$(cat "$out")"
      detail="''${detail//"$user"/<redacted>}"
      detail="''${detail//"$pass"/<redacted>}"
      echo "unifi-mongodb-probe: write path did not report success: $detail" >&2
      exit 1
    fi

    echo "unifi-mongodb-probe: native authenticated write path healthy"
  '';
}
