# UniFi: native MongoDB 8.0

Date: 2026-09-06. Status: production native 8.0.29, stable **FCV 8.0**;
operator explicitly ended burn-in. Signed original release
[PR #206](https://git.ablz.au/abl030/nixosconfig/pulls/206).
Related: [controller history](unifi-controller.md), Forgejo #142 and
[acceptance/closeout #156](https://git.ablz.au/abl030/nixosconfig/issues/156).

## Contract and evidence

`pkgs.mongodb80` repackages the official Ubuntu 24.04 x86_64 MongoDB **8.0.29**
archive with autoPatchelfHook; `dontBuild = true`, no MongoDB compilation.
The [official releases page](https://www.mongodb.com/try/download/community-edition/releases)
and archive checksum were checked on the date above:
`sha256-yJe+lr3aAy3jiIH2Gt2YNIrbACK9l2amlWFglRuW7QA=`.
The small dedicated derivation avoids inheriting nixpkgs mongodb-ce's 8.2
version-dependent metadata. It uses the same vendor-binary packaging approach.

The existing signed rolling updater runs `scripts/update_mongodb80.sh` as an
independent transaction: select only stable 8.0.x, reject downgrade, verify the
official archive checksum and layout, run the existing full check/cache gate,
then sign and push. Failure restores the package file. No second timer and no
automatic 8.2/8.3 selection. HTTPS plus a checksum from the same vendor detects
corruption; it is not independent protection against a compromised vendor.

Native `services.mongodb` uses UID/GID 2015, existing
`/mnt/virtio/unifi-mongodb/db`, authenticated TCP 127.0.0.1:27117, and no daemon
capabilities. Empty state is rejected, not bootstrapped. Root secrets stay 0400
root-only; app secrets are 0400 for the dedicated probe identity. The bounded
root setup unit provisions roles and writes 0600 unifi-owned properties.
UniFi's empty embedded MongoDB substitute, historical migration marker and
message/throwable Logback redaction remain. The marker is NOT a fresh backup.

[MongoDB's 8.0 standalone upgrade guide](https://www.mongodb.com/docs/v8.0/release-notes/8.0-upgrade-standalone/)
requires 7.0 with FCV 7.0 and recommends burn-in before FCV 8.0.
[Community binary downgrade is unsupported](https://www.mongodb.com/docs/v8.0/release-notes/8.0-downgrade/):
FCV 7.0 does not make an 8.0-written dbpath safe to open with 7.0.

The isolated regression `nix/checks/test_unifi_mongodb_native.py` exercised real
7.0.40 and 8.0.29 vendor binaries: cold backup restored into a separate path,
authenticated readback, upgrade retaining FCV 7.0, generated role setup,
application insert/read/delete, failed credentials, renderer and restart.
This is NOT a production-data restore or a UniFi/device end-to-end test.

Additional code-validation evidence (2026-09-06): the opt-in
`nix/checks/test_unifi_mongodb_systemd.py` realizes the actual doc2-generated
daemon/setup/renderer with fixture paths using
`nix/checks/unifi-mongodb-systemd-fixture.nix`. Run from the checkout with
`python3 nix/checks/test_unifi_mongodb_systemd.py --receipt-dir /tmp/mongodb80-systemd-receipts`.
It requires noninteractive sudo, uses only temporary task units and private
loopback networking, and removes synthetic data/credentials in cleanup. It
does not create host accounts or alter production services: the daemon uses
the existing nobody identity; renderer/probe identities are synthetic, with
unit-private NSS binds and no host nscd access. Nix is bounded to one job/two
cores. Real tests cover empty-state refusal, privilege drop, private properties,
idempotent provisioning, read-only controller parent/writable data, hidden
sibling storage, root-only symlink denial and restart. This privileged test is
manual, not an automatic flake build action.

`nix/checks/test_rolling_mongodb80_transaction.py` is included in
`mongodb80UpdaterCheck`. It extracts the actual transaction functions and fatal
finalization guard; only updater/build/git/notification boundaries are mocked.
Nine cases cover success/no-change, update/check/cache-build/stage/commit
failures, and reset/checkout poisoning with later-group and finalization denial.
No real git commit or push occurs. Fixture executables resolve Bash rather than
assuming `/bin/bash` exists on NixOS.

## EOL enforcement

`nix/lib/mongodb80-eol.nix` owns the sole production deadline, **2029-10-31**.
The [official MongoDB Server lifecycle table](https://www.mongodb.com/legal/support-policy/lifecycles)
was verified on 2026-09-06. It is published under Enterprise Advanced; we adopt
that date as our Community retirement policy, not a commercial support entitlement.
The guard fails starting **2029-11-01 UTC**, and names each enabled native
`services.mongodb` consumer whose package is still 8.0. Disabled consumers and
other series do not retain this gate. Future migration still replaces the
separate existing 8.0 package/integration contract as part of its reviewed change.

`mongodb80EolCheck` evaluates the pure policy using the signed
`fleet/freshness.json` date, with eight before/on/after/disabled/other-series/
empty/malformed-date tests. An archived source date is not today's clock:
`check_mongodb80_eol` in the existing rolling updater supplies the live UTC date
to the **same** policy before any group, even on no-change runs, and again after
the builds before heartbeat/signing/push. Failure is fatal, not a skipped group;
it cannot emit a new green heartbeat. Existing signing fixtures exercise both
fatal positions and deny heartbeat/push/deploy after rejection.

These are evaluation/update checks, not continuous runtime expiry. The existing
nightly updater surfaces the failure through its normal failed-run notification;
if it never runs, no new check magically occurs. There is no build-time wallclock,
`builtins.currentTime`, second timer, EOL shutdown, or automatic database change.

## Upstream migration trigger (2026-09-06)

`mongodb80UpstreamGuard` in `nix/checks/unifi.nix` inspects the locked nixpkgs
NixOS UniFi module's `mongodbPackage` option default, using an independent
`lib.nixosSystem` with no local modules, overlays or inherited package config.
It does not inspect our `mongodbAbsent` override or the generic MongoDB package.
While the native package exposes `passthru.mongodbSeries = "8.0"`, an upstream
default beyond 8.0 rejects evaluation with a deliberate-migration prompt. Missing,
ambiguous, throwing or malformed defaults fail closed. Embedded regression cases
exercise numeric boundaries (including 8.10 and later majors), invalid metadata,
inactive-series laziness and non-forcing of package derivations.

The ordinary check set includes this guard; the existing rolling updater's core
transaction runs `FULL_CHECK=1 nix flake check` against its freshly cloned Forgejo
candidate after moving nixpkgs/Home Manager. A rejection rolls that group back
through the existing failure path; it does not automatically bump MongoDB or FCV.
No-change groups skip this gate, unlike the separate live-date EOL preflight.
The deployed updater script is store-backed, but the checked flake is read from
the fresh clone: this check-only source change needs no updater activation or
database deployment. Completion evidence is attached to closed Forgejo #156.

## FCV finalization evidence (2026-09-06)

- User accepted the retained proven7 recovery point and explicitly authorized
  FCV8.0. Live preflight: native8.0.29, stableFCV7, full native verifier passed,
  fresh controller10.6.101 login and all five adopted devices connected.
- Both retained7 archives were rehashed successfully on doc2 and doc1. A **new
  stopped-data paired backup** was taken with current native8.0.29/FCV7 before
  the irreversible feature change. Writes stopped01:09:01 UTC; MongoDB and
  controller restarted01:09:25 UTC. No inconsistent live tar was used.
- New recovery directory on doc2:
  `/mnt/virtio/unifi-pre-fcv8-20260906T010900Z`; restricted off-host copy on doc1:
  `/home/abl030/unifi-mongodb80-release-20260906/unifi-pre-fcv8-20260906T010900Z`.
  `recovery.tar` SHA-256
  `8f5473025c79050a33703a538cb9103397e3e330d60c4e968b34fe0f57a04c01`
  passed independently at both locations (directories0700/archive0600).
  The native system closure is GC-rooted beside the backup.
- At01:10:22 UTC the explicit authenticated mongosh stdin operator command
  `setFeatureCompatibilityVersion:"8.0",confirm:true` completed. Readback was
  `{version:"8.0"}` with **no targetVersion**, on server8.0.29. Credentials were
  read only in-memory from the established scoped secret files, not argv/env.
- Full `unifi-mongodb-verify` passed afterward, including authenticated writes,
  loopback-only listener, private properties and controller status. A fresh API
  login confirmed10.6.101 and five connected/adopted devices with advancing
  `last_seen`. Receipts: `/tmp/mongodb80-finalize-{preflight,cold-backup,fcv,api-fcv8}.log`
  on doc1; final checkpoint `/tmp/mongodb80-finalize-report.md`.

The new pre-FCV backup contains **8-written data**, not a MongoDB7 restore point.
Recover it only with the retained native8 closure. It has not had a separate
restore rehearsal; the earlier cold7 backup below is the proven7 restore point.
FCV8 is never toggled by restart/setup/update automation. On an FCV command or
acceptance failure, preserve native8 and investigate; never blindly switch to7.
Any restore loses writes after its recovery point. Restoring the retained7
backup specifically loses all writes since00:26:27 UTC; FCV is not a downgrade
guarantee, and7 must never open8-written data. Keep both backups restricted.

## Original production migration evidence (2026-09-06, FCV7 burn-in phase)

- Signed candidate `6cc45e3f115b19f888aa3b1bba41bdd4d84ffb75`, release merge
  `a8d3db8c53099db1ef5052c0dc83f18ed3bf7624`. Every signature verified `G`;
  the two-parent Forgejo merge tree exactly matched the tested candidate.
  Full flake check and doc2/doc1 toplevel builds passed with one job/two cores.
- Before publication, doc2 `nixos-upgrade.service`/timer and doc1
  `rolling-flake-update.service`/timer were narrowly runtime-masked and checked
  inactive. Only doc2's deploy service was released for `fleet-deploy doc2`.
  Runtime mask links alone are insufficient after NixOS activation: activation
  can start a timer despite a surviving link; check its actual state too.
- Writes stopped at 00:26:27 UTC. Fresh paired cold database/controller backup:
  `/mnt/virtio/unifi-pre-native-20260906T002618Z` on doc2. It retains the rooted
  mongosh client, old system closure GC root, and exported official 7.0.40 image.
  Separate authenticated 7.0.40 restore at
  `/mnt/virtio/unifi-mongodb/restore-test-20260906T002618Z` passed stable FCV7,
  collection equality, business counts and application insert/read/delete;
  the rehearsal container was then stopped/removed before 8.0 started.
- Restricted off-host recovery directory on doc1:
  `/home/abl030/unifi-mongodb80-release-20260906/unifi-pre-native-20260906T002618Z`
  (0700; files 0600). Both transferred archives passed checksum verification:
  `recovery.tar` SHA-256
  `9d23ab197c8e6d9aaa75cd40ca44184092b27323641edf11e348062a82001774`;
  `mongo7-image.tar` SHA-256
  `5bd0dd807f6b8662cc485d56882685ce81771280dc24028ea3241ee5770f1866`.
  These are the current recovery artifacts, not the August legacy copy.
- Doc2 switched successfully and advanced its anchor at 08:28:53 AWST.
  Native executable is the official-binary `mongodb-ce-8.0.29` store output;
  UID/GID2015, zero capability masks, NoNewPrivs1, authenticated loopback
  127.0.0.1:27117. Old MongoDB container/unit are absent. Root authentication,
  app `clusterMonitor`/four database-owner roles, and writes passed. Stored
  business counts match the cold restore: sites3, devices5, WLANs5, networks7,
  admins1 (API-visible sites are a different population).
- Controlled database/setup/controller restart at 00:33:56–00:34:09 UTC
  retained data. Fresh authenticated UniFi 10.6.101 login/API showed all five
  adopted devices connected with advancing `last_seen` after reconciliation.
  Real connection events at 08:28:46 and 08:34:02 AWST contain `REDACTED@`;
  local logs contain neither database password nor raw MongoDB URI userinfo.
- Live acceptance found that UniFi rewrites URI colons with Java
  `Properties.store()` escaping. The verifier now accepts the original and
  escaped equivalent, retaining the loopback/port guard. Its generated-command
  regression reproduced the old failure and passes both positives plus ten
  wrong-port/host/scheme/auth negatives. This does not change daemon or renderer.
- Fresh application backup completed at 08:36:20 AWST:
  `/mnt/virtio/unifi/data/backup/10.6.101.unf`, 23,659,248 bytes. Restricted
  off-host copy `~/unifi-mongodb80-release-20260906/post-native-10.6.101.unf`
  on doc1 has matching SHA-256
  `7760282485f4c64ab01bf803f7b32b029941aa6dc80f889ea13dff00c363562f`.
  The actual 10.6.101 frontend uses `cmd/backup` with `async-backup`, `days=-1`;
  generic MCP `generate-backup` was unsupported and `cmd/system backup` did
  not produce a new artifact. Existing API `autobackup=false` was not changed.
- Doc1 was activated through `sudo fleet-update --rev a8d3db8c...`, not merely
  a source merge. Its live rolling wrapper contains the mandatory `mongodb80`
  transaction; the timer is scheduled for 23:00 AWST. No extra nightly updater
  job was started. Exact final verifier revision/maintenance release receipts
  are recorded in #156 and `/tmp/mongodb80-release-report.md` on doc1.

Keep FCV7 until a separately approved burn-in acceptance and NEW recovery point.
Neither migration closeout nor automatic patch updates authorize FCV8. Retain
the cold backup, restored test data, old image and closure through that decision.

## Reusable operator cutover

Keep automatic doc2 updates from racing this maintenance window using the
existing fleet maintenance procedure. Do not release this change into an
unattended deploy before the backup/restore steps below. Reserve space for the
cold backup, restore rehearsal, and possible quarantine. Keep the current
7.0.40 image and pre-upgrade NixOS closure until rollback expires.

The following blocks run in the SAME root Bash session on doc2, without xtrace.
They deliberately stop writes before copying. No broad shared-dataset ZFS
rollback, August embedded copy, live filesystem copy, or image-only downgrade.

### 1. Preflight and fresh offline backup

Before running the block, set `REVIEWED_FLAKE` to the absolute path of the
reviewed, signed, root-owned checkout on doc2 (root Nix rejects another user's
Git worktree). It must contain this candidate; do not use an
unversioned remote branch. Building the standalone shell below does not activate
the native database configuration. Its backup-local GC root keeps the client
available across deployment and recovery; retain that link with the backup.

```bash
set -euo pipefail
umask 077
base=/mnt/virtio/unifi-mongodb
stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup=/mnt/virtio/unifi-pre-native-$stamp
install -d -m 0700 "$backup"
test -n "${REVIEWED_FLAKE:?Set the reviewed signed flake checkout path}"
nix build "${REVIEWED_FLAKE}#nixosConfigurations.doc2.pkgs.mongosh" \
  --out-link "$backup/mongosh-client" --max-jobs 1 --cores 2
mongosh_bin="$backup/mongosh-client/bin/mongosh"
test -x "$mongosh_bin"
"$mongosh_bin" --version
readlink -f /run/current-system > "$backup/system-path"
podman inspect --format '{{.Image}}' unifi-mongodb > "$backup/mongo7-image"
image=$(< "$backup/mongo7-image")
port=27117
mongo_root() {
  {
    printf '%s\n' 'const fs = require("fs");'
    printf '%s\n' 'const s = n => fs.readFileSync("/run/secrets/unifi-mongodb/" + n,"utf8").trim();'
    printf '%s\n' 'const admin = db.getSiblingDB("admin"); if (!admin.auth(s("root-username"),s("root-password"))) quit(11);'
    cat
  } | "$mongosh_bin" --quiet --norc --host 127.0.0.1 --port "$port" --file /dev/stdin
}
check7() {
  mongo_root <<'JS'
if (db.version() !== "7.0.40") throw Error("expected running 7.0.40");
const f = admin.runCommand({getParameter:1,featureCompatibilityVersion:1});
if (f.ok !== 1 || f.featureCompatibilityVersion.version !== "7.0" || f.featureCompatibilityVersion.targetVersion) throw Error("FCV must be stable 7.0");
for (const n of ["ace","ace_stat","ace_audit"]) print(n + " collections=" + db.getSiblingDB(n).getCollectionNames().sort().join(","));
if (db.getSiblingDB("ace").getCollectionNames().length === 0) throw Error("missing UniFi data");
print("7.0_VERSION_FCV_AUTH_OK");
JS
}
require_inactive() {
  local state
  state=$(systemctl show --property=ActiveState --value "$1") || return 1
  if [ "$state" != inactive ]; then
    printf 'Expected inactive service: %s (state=%s)\n' "$1" "$state" >&2
    return 1
  fi
}
require_container_stopped() {
  local running
  # A successful query with no row includes the normal post-stop removal case.
  running=$(podman ps --all --filter 'name=^unifi-mongodb$' \
    --format '{{.State}}') || return 1
  case "$running" in
    ''|exited|stopped) return 0 ;;
    *) printf 'Unexpected MongoDB container state: %s\n' "$running" >&2; return 1 ;;
  esac
}
systemctl is-active --quiet unifi.service
systemctl is-active --quiet podman-unifi-mongodb.service
systemctl stop unifi.service
require_inactive unifi.service
check7 > "$backup/preflight.txt"
systemctl stop podman-unifi-mongodb.service
require_inactive podman-unifi-mongodb.service
# Stop failure must not be ignored; confirm the container is not running.
require_container_stopped
test -s "$base/db/storage.bson"
cp -a --reflink=auto "$base/db" "$backup/db"
cp -a --reflink=auto /mnt/virtio/unifi "$backup/unifi"
# Independent archival copy; transfer to restricted off-host storage and verify.
tar -C "$backup" -cpf "$backup/recovery.tar" db unifi system-path mongo7-image
(cd "$backup"; sha256sum recovery.tar > recovery.tar.sha256)
```

Record the backup path. Transfer `recovery.tar` plus its checksum to the
operator's approved restricted off-host backup destination and verify with
`sha256sum -c recovery.tar.sha256` there before continuing. The archive contains
controller credentials: never put it in public storage or source control.
If FCV preflight fails, stop here; resolve the existing 7.0 state separately.

### 2. Demonstrate restore BEFORE any 8.0 start

```bash
restore="$base/restore-test-$stamp"
test ! -e "$restore"
cp -a --reflink=auto "$backup/db" "$restore"
chown -R 2015:2015 "$restore"
podman run -d --name unifi-mongo7-restore-test --pull=never \
  --network=host --user=2015:2015 --cap-drop=all \
  --security-opt=no-new-privileges --read-only --tmpfs /tmp \
  --entrypoint mongod -v "$restore:/data/db:rw" \
  "$image" --dbpath /data/db --auth --bind_ip 127.0.0.1 --port 27118 --nounixsocket
port=27118
for _ in {1..30}; do
  if check7 > "$backup/restore-readback.txt" 2>/dev/null; then break; fi
  sleep 1
done
check7 > "$backup/restore-readback.txt"
cmp "$backup/preflight.txt" "$backup/restore-readback.txt"
mongo_root <<'JS'
if (!admin.auth(s("app-username"),s("app-password"))) throw Error("app auth failed");
const c = db.getSiblingDB("ace").getCollection("_rollback_probe"), id = new ObjectId();
c.insertOne({_id:id});
if (!c.findOne({_id:id}) || c.deleteOne({_id:id}).deletedCount !== 1) throw Error("app write/read/delete failed");
print("RESTORE_APP_WRITE_OK");
JS
podman stop --time 60 unifi-mongo7-restore-test
podman rm unifi-mongo7-restore-test
# Keep restore-test and immutable backup until acceptance; no broad rm command.
port=27117
```

On any failure, stop the rehearsal container and leave production on 7.0; do
not start 8.0. Also inspect representative site/device counts in the restored
`ace` database against the live baseline. Collection-list equality and a probe
alone are not full business-data acceptance.

### 3. Cut over and verify

After independent review/release and successful restore, from doc1 run
`fleet-deploy doc2`. It is asynchronous: wait for completion and verify the
running revision equals the reviewed signed release before health acceptance.
There is no `--target-host` or local worktree deployment.

On doc2:

```bash
systemctl is-active mongodb.service unifi-mongodb-setup.service unifi.service
unifi-mongodb-verify
mongo_root <<'JS'
if (!db.version().startsWith("8.0.")) throw Error("wrong version");
const f = admin.runCommand({getParameter:1,featureCompatibilityVersion:1});
if (f.ok !== 1 || f.featureCompatibilityVersion.version !== "7.0") throw Error("FCV changed unexpectedly");
print("NATIVE_8_FCV_7_OK");
JS
```

Verify admin login, expected sites/devices, advancing device last_seen, normal
backups, a controlled restart, and useful redacted logs. Do not print properties
or secret files. Leave FCV 7.0 through the agreed burn-in. Only after acceptance
and a NEW recovery point, explicitly run `mongo_root` with
`if (admin.runCommand({setFeatureCompatibilityVersion:"8.0",confirm:true}).ok !== 1) throw Error("FCV change failed");`
and read back `getParameter:1,featureCompatibilityVersion:1`. No service or
updater changes FCV automatically.

## Recovery: restore fresh 7.0 data, THEN the old service definition

Use the exact backup path recorded above (restore variables/functions from
preflight if reconnecting). This loses writes since that recovery point; retain
the 8.0 quarantine for incident analysis. Stop automatic deployment first.

```bash
systemctl stop unifi.service mongodb.service
systemctl mask --runtime mongodb.service unifi.service
require_inactive mongodb.service
require_inactive unifi.service
(cd "$backup"; sha256sum -c recovery.tar.sha256)
test ! -e "$base/db-8-quarantine-$stamp"
mv "$base/db" "$base/db-8-quarantine-$stamp"
cp -a --reflink=auto "$backup/db" "$base/db"
chown -R 2015:2015 "$base/db"
# Preserve the controller mount's root; restore its contents, not the mount.
cp -a --reflink=auto /mnt/virtio/unifi "$backup/unifi-after-failure"
find /mnt/virtio/unifi -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "$backup/unifi/." /mnt/virtio/unifi/
previous=$(< "$backup/system-path")
test -x "$previous/bin/switch-to-configuration"
# Explicit break-glass configuration activation is permitted ONLY after restore.
"$previous/bin/switch-to-configuration" switch
systemctl start podman-unifi-mongodb.service
port=27117
check7
systemctl unmask --runtime unifi.service
systemctl start unifi.service
systemctl is-active podman-unifi-mongodb.service unifi.service
```

Recheck app writes, login and device check-in. Keep native MongoDB runtime-masked
until a new approved attempt, and reconcile the fleet source to the reviewed
7.0 configuration before automatic updates resume. Merely switching generation
or image without restoring the fresh 7.0 backup is never rollback.
