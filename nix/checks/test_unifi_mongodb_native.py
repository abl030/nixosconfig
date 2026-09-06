#!/usr/bin/env python3
"""Isolated real-binary regression; no systemd, production paths or credentials.

Pass realized doc2 artifacts in the named environment variables. Optional
MONGODB7_BIN rehearses a cold 7.0 backup/restore and 7->8 upgrade with fake data.
Only fixture paths/port and the setup retry deadline are remapped. The renderer's
unprivileged phase runs as the caller; the root/systemd boundary is eval-tested.
"""
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=35, **kwargs)


def main():
    mongod = os.environ["MONGODB80_BIN"]
    mongosh = os.environ["MONGOSH_BIN"]
    setup_source = Path(os.environ["MONGO_SETUP"]).read_text()
    probe = os.environ["MONGO_PROBE"]
    verifier_source = Path(os.environ["MONGO_VERIFY"]).read_text()
    previous = os.environ.get("MONGODB7_BIN")
    process = None
    with tempfile.TemporaryDirectory(prefix="unifi-mongodb-native-test-") as temp:
        root = Path(temp)
        dbpath = root / "db"
        dbpath.mkdir()
        home = root / "home"
        home.mkdir()
        environment = dict(os.environ, HOME=str(home))
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        user, password = "FixtureApp", "FixtureAppPassword"
        secret_dir = root / "secrets"
        secret_dir.mkdir(mode=0o700)
        for name, value in {"root-username": "FixtureRoot", "root-password": "FixtureRootPassword",
                            "app-username": user, "app-password": password}.items():
            path = secret_dir / name
            path.write_text(value)
            path.chmod(0o400)
        state = root / "unifi"
        (state / "data").mkdir(parents=True)

        def shell(js):
            return run([mongosh, "--quiet", "--norc", "--host", "127.0.0.1", "--port", str(port),
                        "--file", "/dev/stdin"], input=js, env=environment)

        auth = 'db.getSiblingDB("admin").auth("FixtureRoot", "FixtureRootPassword");\n'

        def checked(js):
            result = shell(auth + js)
            assert result.returncode == 0, result.stdout + result.stderr
            return result.stdout

        def start(binary):
            nonlocal process
            logfile = root / "mongod.log"
            output = logfile.open("a")
            process = subprocess.Popen([binary, "--dbpath", str(dbpath), "--bind_ip", "127.0.0.1",
                                        "--port", str(port), "--auth", "--nounixsocket",
                                        "--wiredTigerCacheSizeGB", "0.25"], stdout=output, stderr=output)
            output.close()
            for _ in range(100):
                if process.poll() is not None:
                    raise AssertionError(logfile.read_text()[-5000:])
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        return
                except OSError:
                    time.sleep(0.1)
            raise AssertionError("fixture server did not start")

        def stop():
            nonlocal process
            if process is not None:
                process.terminate()
                try:
                    process.wait(timeout=25)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise
                assert process.returncode == 0, process.returncode
                process = None

        def remap(text):
            return (text.replace("/run/secrets/unifi-mongodb", str(secret_dir))
                    .replace("/mnt/virtio/unifi", str(state)).replace("27117", str(port)))

        try:
            start(previous or mongod)
            result = shell('db.getSiblingDB("admin").createUser({user:"FixtureRoot",pwd:"FixtureRootPassword",roles:["root"]});')
            assert result.returncode == 0, result.stdout + result.stderr
            checked('db.getSiblingDB("ace").fixture.insertOne({_id:"salvage",value:42});')
            if previous:
                checked('if (db.version() !== "7.0.40" || db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version !== "7.0") throw Error("bad 7.0 baseline");')
                stop()
                backup = root / "cold-backup-7"
                shutil.copytree(dbpath, backup)
                restored = root / "restore-test-7"
                shutil.copytree(backup, restored)
                original = dbpath
                dbpath = restored
                start(previous)
                checked('if (db.getSiblingDB("ace").fixture.findOne({_id:"salvage"}).value !== 42) throw Error("restore failed");')
                stop()
                dbpath = original
                print("PASS cold 7.0.40 backup restored into fresh path and authenticated readback")
                start(mongod)
                checked('if (db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version !== "7.0") throw Error("FCV changed during upgrade");')
                print("PASS 7.0.40 -> 8.0 upgrade preserves fixture data and FCV 7.0")

            setup = root / "setup"
            setup.write_text(remap(setup_source).replace("SECONDS + 180", "SECONDS + 2"))
            setup.chmod(0o700)
            for _ in range(2):
                result = run(["bash", str(setup)], env=environment)
                assert result.returncode == 0, result.stdout + result.stderr
            assert not (state / "data/system.properties").exists()
            print("PASS generated setup authenticates, provisions role idempotently, respects absent marker")

            probe_environment = dict(environment, UNIFI_MONGO_PORT=str(port), UNIFI_MONGO_MONGOSH=mongosh,
                                     UNIFI_MONGO_USER_FILE=str(secret_dir / "app-username"),
                                     UNIFI_MONGO_PASSWORD_FILE=str(secret_dir / "app-password"))
            result = run([probe], env=probe_environment)
            assert result.returncode == 0, result.stdout + result.stderr
            print("PASS exact generated application insert/read/delete probe")
            bad = root / "bad-password"
            bad.write_text("WrongFixturePassword")
            result = run([probe], env=dict(probe_environment, UNIFI_MONGO_PASSWORD_FILE=str(bad)))
            assert result.returncode != 0
            assert "failed" in result.stderr.lower()
            assert "WrongFixturePassword" not in result.stderr and user not in result.stderr
            print("PASS bad credentials fail with useful redacted diagnostics")
            assert shell('throw new Error("fixture uncaught");').returncode != 0
            print("PASS script mode propagates uncaught JavaScript failures")

            # Execute the exact verifier's listener expression against the real socket.
            expression = next(line for line in remap(verifier_source).splitlines() if line.strip().startswith('listeners='))
            result = run(["bash", "-c", expression + '\nprintf "%s" "$listeners"'])
            assert result.returncode == 0 and result.stdout == f"127.0.0.1:{port}", result
            print("PASS generated verifier detects the real loopback-only TCP listener")

            renderer_match = re.search(r"/nix/store/[^\s]+/bin/unifi-mongodb-render-system-properties", setup_source)
            assert renderer_match is not None
            renderer = renderer_match.group()
            text = remap(Path(renderer).read_text())
            renderer_fixture = root / "renderer"
            renderer_fixture.write_text(text)
            properties = state / "data/system.properties"
            original_properties = "is_setup_completed=true\ncustom.setting=preserved\ndb.mongo.local=true\n"
            properties.write_text(original_properties)
            for _ in range(2):
                result = run(["bash", str(renderer_fixture), "--unprivileged"], input=f"{user}\n{password}\n", env=environment)
                assert result.returncode == 0, result.stderr
            rendered = properties.read_text()
            assert "custom.setting=preserved" in rendered and "db.mongo.local=false" in rendered
            assert f"{user}:{password}@127.0.0.1:{port}/ace?authSource=admin" in rendered
            assert properties.stat().st_mode & 0o777 == 0o600
            assert Path(str(properties) + ".pre-native-mongodb80").read_text() == original_properties
            print("PASS generated renderer preserves settings/backup and writes correct private credential URI")

            stop()
            start(mongod)
            result = run([probe], env=probe_environment)
            assert result.returncode == 0, result.stderr
            checked('if (db.getSiblingDB("ace").fixture.findOne({_id:"salvage"}).value !== 42) throw Error("data lost");')
            print("PASS native restart retains data and authenticated write path")
        finally:
            stop()
    print("PASS fixture processes stopped and temporary database/credentials removed")


if __name__ == "__main__":
    main()
