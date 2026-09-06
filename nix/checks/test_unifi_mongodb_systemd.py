#!/usr/bin/env python3
"""Opt-in privileged test of generated units, using task-only paths and networking.

Run as an ordinary user with noninteractive sudo, from the repository root:
  python3 nix/checks/test_unifi_mongodb_systemd.py --receipt-dir /tmp/mongo-receipts
No host accounts, persistent units, production paths, or security settings change.
Nix only realizes fixture scripts/config and the existing binary MongoDB package.
"""
import argparse
import json
import os
import shlex
import subprocess
import time
from pathlib import Path


def run(args, check=True, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=60, **kwargs)
    if check and result.returncode:
        raise AssertionError(f"{args!r}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt-dir", required=True, type=Path)
    args = parser.parse_args()
    receipts = args.receipt_dir.resolve()
    receipts.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[2]
    run(["sudo", "-n", "true"])
    root = Path(run(["sudo", "-n", "mktemp", "-d", "/var/lib/mongodb80-systemd-test-XXXXXXXX"]).stdout.strip())
    assert root.parent == Path("/var/lib") and root.name.startswith("mongodb80-systemd-test-")
    run(["sudo", "-n", "chown", f"{os.getuid()}:{os.getgid()}", str(root)])
    root.chmod(0o755)
    prefix = root.name
    units = []
    manifest = None
    net_path = None
    # systemd resolves even numeric User= before unit-private NSS binds. Use the
    # existing unprivileged nobody identity for the daemon, never create users.
    db_uid = int(run(["getent", "passwd", "nobody"]).stdout.split(":")[2])
    db_gid = int(run(["getent", "passwd", "nobody"]).stdout.split(":")[3])
    app_uid, probe_uid = 62016, 62017
    for uid in (app_uid, probe_uid):
        assert run(["getent", "passwd", str(uid)], check=False).returncode == 2
        assert run(["getent", "group", str(uid)], check=False).returncode == 2

    def sudo(*command, **kwargs):
        return run(["sudo", "-n", *map(str, command)], **kwargs)

    def properties(values):
        result = []
        for key, value in values.items():
            if isinstance(value, bool):
                value = "yes" if value else "no"
            elif isinstance(value, list):
                value = " ".join(map(str, value))
            result.append(f"--property={key}={value}")
        return result

    def unit(label, config, command=None, wait=False, expected=0):
        name = f"{prefix}-{label}.service"
        units.append(name)
        values = dict(config)
        executable = command or shlex.split(values.pop("ExecStart"))
        values.pop("ExecStart", None)
        # Preserve generated ExecStartPre through the transient exec setter.
        values.update({"PrivateNetwork": True,
                       # Unit-private passwd must not resolve through host nscd.
                       "InaccessiblePaths": "-/run/secrets -/run/nscd -/mnt -/home -/root",
                       "MemoryMax": "1G", "CPUQuota": "200%", "TasksMax": 128,
                       "RuntimeMaxSec": 480})
        if label != "net":
            assert net_path is not None
            # Join only networking: JoinsNamespaceOf can also share PrivateTmp
            # and accidentally change the service's writable /tmp contract.
            values["NetworkNamespacePath"] = net_path
        call = ["systemd-run", "--quiet", "--collect", f"--unit={name}"]
        if wait:
            call += ["--wait", "--pipe"]
        call += properties(values) + executable
        result = sudo(*call, check=False)
        (receipts / f"{label}.txt").write_text(result.stdout + result.stderr)
        assert (result.returncode == 0) == (expected == 0), (label, result.returncode, result.stdout, result.stderr)
        return name

    def stop(name):
        sudo("systemctl", "stop", name, check=False)

    def script(name, content):
        assert manifest is not None
        target = root / name
        target.write_text(f"#!{manifest['bash']}\nset -euo pipefail\n" + content)
        target.chmod(0o755)
        return [str(target)]

    try:
        for directory in ("mnt/mongodb/db", "mnt/unifi/data", "runtime", "secrets", "home"):
            (root / directory).mkdir(parents=True)
        secret_values = {"root-username": "FixtureRoot", "root-password": "FixtureRootPassword",
                         "app-username": "FixtureApp", "app-password": "FixtureAppPassword"}
        for name, value in secret_values.items():
            path = root / "secrets" / name
            path.write_text(value)
            path.chmod(0o400)
            owner = probe_uid if name.startswith("app-") else 0
            sudo("chown", f"{owner}:{owner}", path)
        sudo("chmod", "0711", root / "secrets")
        sudo("chown", "0:0", root / "secrets")
        for directory, uid, gid in ((root / "mnt/mongodb", db_uid, db_gid), (root / "mnt/unifi", app_uid, app_uid), (root / "runtime", db_uid, db_gid)):
            sudo("chown", "-R", f"{uid}:{gid}", directory)
        sudo("chmod", "0700", root / "mnt/unifi")
        sudo("chmod", "0750", root / "mnt/mongodb", root / "mnt/mongodb/db")
        passwd = root / "passwd"
        passwd.write_text(f"root:x:0:0:root:{root}/home:/bin/false\nunifi:x:{app_uid}:{app_uid}:fixture:{root}/home:/bin/false\n")
        group = root / "group"
        group.write_text(f"root:x:0:\nunifi:x:{app_uid}:\n")
        expression = (f"import {repo}/nix/checks/unifi-mongodb-systemd-fixture.nix {{ "
                      f"flake = builtins.getFlake {json.dumps(str(repo))}; fixtureRoot = {json.dumps(str(root))}; }}")
        (receipts / "fixture-expression.nix").write_text(expression)
        built = subprocess.run(["nix", "build", "--impure", "--no-link", "--print-out-paths", "--max-jobs", "1", "--cores", "2",
                                "--expr", expression], text=True, capture_output=True, timeout=300)
        (receipts / "nix-build.txt").write_text(built.stdout + built.stderr)
        assert built.returncode == 0, built.stderr
        artifact = Path(built.stdout.strip())
        manifest = json.loads(artifact.read_text())
        (receipts / "manifest.json").write_text(json.dumps(manifest, indent=2))
        print(f"ARTIFACT {artifact}", flush=True)
        # These are only fixture substitutions. All other generated service
        # properties, pre-start, setup, and renderer are consumed unchanged.
        daemon = dict(manifest["daemon"])
        daemon.update(User=str(db_uid), Group=str(db_gid), RuntimeDirectory=f"{prefix}-runtime",
                      Environment=[f"{k}={v}" for k, v in manifest["daemonEnvironment"].items()], Restart="no")
        # Fixture pidFile is outside RuntimeDirectory; preserve its writable equivalent.
        daemon["ReadWritePaths"] += [str(root / "runtime")]
        setup = dict(manifest["setup"])
        setup.update(RemainAfterExit=False,
                     TemporaryFileSystem=["/mnt", str(root / "mnt")],
                     BindReadOnlyPaths=setup["BindReadOnlyPaths"] + [f"{passwd}:/etc/passwd", f"{group}:/etc/group"],
                     Environment=[f"HOME={root}/home"])
        # Probe environment writes must not weaken the generated sandbox.
        env_path = manifest["coreutils"] + ":" + manifest["utilLinux"]
        setup["Environment"].append(f"PATH={env_path}")
        unit("net", {"Type": "exec", "ProtectSystem": "strict", "RuntimeMaxSec": 480},
             [manifest["coreutils"] + "/sleep", "480"])
        net_pid = sudo("systemctl", "show", "--value", "-p", "MainPID", f"{prefix}-net.service").stdout.strip()
        net_path = f"/proc/{net_pid}/ns/net"
        assert sudo("readlink", net_path).stdout != sudo("readlink", "/proc/1/ns/net").stdout

        def shell(js):
            return sudo(manifest["utilLinux"] + "/nsenter", f"--net={net_path}",
                        "--", manifest["coreutils"] + "/env", f"HOME={root}/home",
                        manifest["mongosh"], "--quiet", "--norc", "--host", "127.0.0.1", "--port", "37117",
                        "--file", "/dev/stdin", input=js)

        empty_unit = unit("empty-state", daemon, wait=True, expected=1)
        empty_journal = sudo("journalctl", "--no-pager", "-u", empty_unit, "-n", "30").stdout
        assert "refusing empty initialization" in empty_journal + (receipts / "empty-state.txt").read_text(), empty_journal
        sudo("test", "!", "-e", root / "mnt/mongodb/db/storage.bson")
        print("PASS generated daemon pre-start rejects empty storage under real systemd", flush=True)
        bootstrap = dict(daemon)
        for key in ("ExecStartPre", "PIDFile"):
            bootstrap.pop(key, None)
        bootstrap["Type"] = "exec"
        boot_unit = unit("bootstrap", bootstrap,
                         [manifest["mongod"], "--dbpath", str(root / "mnt/mongodb/db"), "--bind_ip", "127.0.0.1",
                          "--port", "37117", "--auth", "--nounixsocket", "--wiredTigerCacheSizeGB", "0.25"])
        for attempt in range(30):
            result = sudo(manifest["utilLinux"] + "/nsenter", f"--net={net_path}", "--", manifest["bash"], "-c",
                          "true > /dev/tcp/127.0.0.1/37117", check=False)
            if result.returncode == 0:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("bootstrap never listened")
        shell('db.getSiblingDB("admin").createUser({user:"FixtureRoot",pwd:"FixtureRootPassword",roles:["root"]});')
        stop(boot_unit)
        sudo("test", "-s", root / "mnt/mongodb/db/storage.bson")
        native_unit = unit("native", daemon)
        effective = sudo("systemctl", "show", native_unit, "-p", "ProtectSystem", "-p", "ReadWritePaths", "-p", "RuntimeDirectory", "-p", "PrivateTmp", "-p", "User").stdout
        (receipts / "daemon-effective.txt").write_text(effective)
        pid = sudo("systemctl", "show", "--value", "-p", "MainPID", native_unit).stdout.strip()
        status = sudo("cat", f"/proc/{pid}/status").stdout
        selected = "\n".join(line for line in status.splitlines() if line.startswith(("Uid:", "Gid:", "Cap", "NoNewPrivs:")))
        (receipts / "daemon-privileges.txt").write_text(selected + "\n")
        assert f"Uid:\t{db_uid}\t{db_uid}\t{db_uid}\t{db_uid}" in status
        assert "CapEff:\t0000000000000000" in status and "NoNewPrivs:\t1" in status
        print("PASS actual generated mongod ExecStart runs with no capabilities and non-root UID", flush=True)
        for attempt in range(2):
            unit(f"setup-no-marker-{attempt}", setup, wait=True)
        sudo("test", "!", "-e", root / "mnt/unifi/data/system.properties")
        marker = root / "mnt/unifi/migrated-to-external-mongodb"
        sudo("touch", marker)
        original = "custom.setting=preserved\ndb.mongo.local=true\n"
        properties_file = root / "mnt/unifi/data/system.properties"
        sudo(manifest["bash"], "-c", f"printf %s {shlex.quote(original)} > {shlex.quote(str(properties_file))}")
        sudo("chown", f"{app_uid}:{app_uid}", properties_file)
        for attempt in range(2):
            unit(f"setup-render-{attempt}", setup, wait=True)
        rendered = sudo("cat", properties_file).stdout
        assert "custom.setting=preserved" in rendered and "FixtureApp:FixtureAppPassword@127.0.0.1:37117" in rendered
        assert sudo("stat", "-c", "%a %u:%g", properties_file).stdout.strip() == f"600 {app_uid}:{app_uid}"
        backup = Path(str(properties_file) + ".pre-native-mongodb80")
        assert sudo("cat", backup).stdout == original
        shell('db.getSiblingDB("admin").auth("FixtureApp","FixtureAppPassword"); var c=db.getSiblingDB("ace").fixture; c.insertOne({_id:"sandbox",value:42}); if(c.findOne({_id:"sandbox"}).value!==42) throw Error("readback"); c.deleteOne({_id:"sandbox"});')
        print("PASS generated setup and root-to-UniFi renderer: idempotence, owner/mode, backup and application writes", flush=True)
        # Test mounts using the generated setup envelope, not host DAC guesses.
        canary = root / "mnt/sibling-canary"
        canary.write_text("hidden")
        probe_text = f'''test ! -e {canary}
findmnt --target {root}/mnt/unifi
findmnt --target {root}/mnt/unifi/data
if touch {root}/mnt/unifi/forbidden 2>/dev/null; then exit 81; fi
{manifest['utilLinux']}/setpriv --reuid=unifi --regid=unifi --clear-groups --inh-caps=-all --ambient-caps=-all \\
  {manifest['bash']} -c 'touch {root}/mnt/unifi/data/allowed; test ! -r {root}/secrets/root-password; test ! -r {root}/secrets/app-password'
printf 'PASS setup read-only parent, writable data, hidden sibling, credentials denied after drop\\n'
'''
        unit("setup-mount-probe", setup, script("setup-mount-probe", probe_text), wait=True)
        # Root-only canary symlink attacks must fail in the actual renderer.
        canary = root / "root-canary"
        canary.write_text("RootOnlyCanaryMustNotLeak")
        sudo("chown", "0:0", canary)
        sudo("chmod", "0600", canary)
        for label, victim, expected in (("source-symlink", properties_file, 1), ("backup-symlink", backup, 0)):
            sudo("rm", "-f", victim)
            sudo("ln", "-s", canary, victim)
            # An existing backup is deliberately never opened or overwritten;
            # even a hostile existing backup symlink is harmless to this run.
            unit(label, setup, wait=True, expected=expected)
            assert sudo("cat", canary).stdout == "RootOnlyCanaryMustNotLeak"
            output = (receipts / f"{label}.txt").read_text()
            assert "RootOnlyCanaryMustNotLeak" not in output
            if expected:
                assert "Permission denied" in output, output
            sudo("rm", "-f", victim)
            if victim == properties_file:
                sudo(manifest["bash"], "-c", f"printf %s {shlex.quote(original)} > {properties_file}")
                sudo("chown", f"{app_uid}:{app_uid}", properties_file)
        print("PASS real renderer denies root-only source reads and leaves existing backup symlink targets untouched", flush=True)
        daemon_probe = dict(daemon)
        for key in ("ExecStartPre", "PIDFile"):
            daemon_probe.pop(key, None)
        daemon_probe["Type"] = "oneshot"
        outside = root / "outside-db"
        outside.mkdir(mode=0o777)
        outside.chmod(0o777)
        unit("daemon-mount-probe", daemon_probe, script("daemon-mount-probe", f'''
export PATH={env_path}
findmnt --target {outside}
findmnt --target {root}/mnt/mongodb/db
touch {root}/mnt/mongodb/db/allowed
if touch {outside}/forbidden 2>/dev/null; then exit 82; fi
test ! -r {root}/secrets/root-password
printf 'PASS daemon writable database, read-only outside, root credential denial\\n'
'''), wait=True)
        print("PASS generated daemon/setup writable-path and mount restrictions exercised", flush=True)
        stop(native_unit)
        native_unit = unit("native-restart", daemon)
        unit("setup-after-restart", setup, wait=True)
        print("PASS generated native restart and authenticated setup after restart", flush=True)
    finally:
        for name in reversed(units):
            journal = sudo("journalctl", "--no-pager", "-u", name, "-n", "100", check=False)
            # Synthetic-only journal, still assert credentials are not logged.
            text = journal.stdout + journal.stderr
            (receipts / f"{name}.journal.txt").write_text(text)
            stop(name)
            sudo("systemctl", "reset-failed", name, check=False)
        remaining = sudo("systemctl", "list-units", "--all", "--plain", "--no-legend", f"{prefix}*").stdout
        (receipts / "cleanup-units.txt").write_text(remaining)
        assert not remaining.strip(), remaining
        sudo("rm", "-rf", "--", root)
        assert not root.exists()
        print("PASS task units stopped/collected and synthetic database/credentials removed", flush=True)
    for path in receipts.glob("*.txt"):
        text = path.read_text()
        assert "FixtureRootPassword" not in text and "FixtureAppPassword" not in text, path
    print("PASS no synthetic passwords in unit output or journals", flush=True)


if __name__ == "__main__":
    main()
