#!/usr/bin/env python3
"""Exercise UniFi's packaged Logback stack with a redaction configuration."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path
from zipfile import ZipFile

FIXTURE_USER = "unifi-redaction-fixture-user"
FIXTURE_PASSWORD = "unifi-redaction-fixture-password"
EXPECTED_PATTERN = (
    r"%replace(%message %ex){'(?i)(mongodb(?:\+srv)?://)[^\s/@]*@',"
    r"'$1REDACTED@'}%n"
)
JAVA_SOURCE = f"""\
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class UnifiLogbackRedactionProbe {{
    private UnifiLogbackRedactionProbe() {{}}

    public static void main(String[] args) {{
        Logger logger = LoggerFactory.getLogger("unifi.logback.redaction.probe");
        String standardUri = "mongodb://{FIXTURE_USER}:{FIXTURE_PASSWORD}@127.0.0.1:27117/ace?authSource=admin";
        String srvUri = "mongodb+srv://{FIXTURE_USER}:{FIXTURE_PASSWORD}@mongo.example.invalid/ace";

        logger.info("ordinary diagnostic preserved");
        logger.info("MongoDB connection diagnostic: " + standardUri);
        try {{
            throw new IllegalStateException("exception diagnostic: " + srvUri);
        }} catch (IllegalStateException error) {{
            logger.warn("ordinary warning preserved", error);
        }}
    }}
}}
"""


def fail(message: str) -> None:
    raise SystemExit(message)


def run_checked(command: list[str], *, cwd: Path) -> None:
    result = subprocess.run(
        command,
        cwd=cwd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        fail(f"command failed with exit {result.returncode}: {command[0]}")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        fail("usage: test_unifi_logback_redaction.py PACKAGE JAVA CONFIG")

    package = Path(argv[1])
    java = Path(argv[2])
    config = Path(argv[3])
    jar = package / "lib" / "ace.jar"
    local_lib = package / "lib" / "local"

    config_text = config.read_text(encoding="utf-8")
    if EXPECTED_PATTERN not in config_text:
        fail("generated Logback configuration lacks the redacted message/exception pattern")
    if config_text.count('name="logPattern"') != 1:
        fail("generated Logback configuration does not preserve the upstream logPattern variable")
    for required in ("server_log", "state_log", "migration_log", "AnalyticsAppender"):
        if required not in config_text:
            fail(f"generated Logback configuration dropped upstream appender {required}")

    # Keep this tied to the installed controller rather than a copied fixture:
    # both resources are present in the current UniFi distribution and the
    # explicit system property must win over either classpath resource.
    with ZipFile(jar) as installed_jar:
        for resource in ("logback.xml", "logback-test.xml"):
            embedded = installed_jar.read(resource).decode("utf-8")
            if embedded.count('name="logPattern"') != 1 or " - %message%n" not in embedded:
                fail(f"installed UniFi resource {resource} changed unexpectedly")

    libraries = [jar, *sorted(local_lib.glob("*.jar"))]
    if not libraries or not all(path.is_file() for path in libraries):
        fail("installed UniFi Logback classpath is incomplete")

    with tempfile.TemporaryDirectory(prefix="unifi-logback-redaction-") as temporary:
        work = Path(temporary)
        source = work / "UnifiLogbackRedactionProbe.java"
        source.write_text(JAVA_SOURCE, encoding="utf-8")
        classpath = os.pathsep.join([str(work), *(str(path) for path in libraries)])
        run_checked([str(java / "bin" / "javac"), "-cp", classpath, str(source)], cwd=work)

        log_dir = work / "logs"
        log_dir.mkdir()
        run_checked(
            [
                str(java / "bin" / "java"),
                f"-Dlogback.configurationFile={config}",
                f"-DlogDir={log_dir}",
                "-cp",
                classpath,
                "UnifiLogbackRedactionProbe",
            ],
            cwd=work,
        )

        log_files = [path for path in log_dir.rglob("*") if path.is_file()]
        if not log_files:
            fail("the real Logback stack did not create a log file")
        output = b"\n".join(path.read_bytes() for path in log_files)
        forbidden = (FIXTURE_USER.encode(), FIXTURE_PASSWORD.encode())
        if any(secret in output for secret in forbidden):
            fail("fixture credential reached a Logback output file")

        required_output = (
            b"ordinary diagnostic preserved",
            b"MongoDB connection diagnostic: mongodb://REDACTED@127.0.0.1:27117/ace",
            b"ordinary warning preserved",
            b"exception diagnostic: mongodb+srv://REDACTED@mongo.example.invalid/ace",
            b"java.lang.IllegalStateException",
            b"at UnifiLogbackRedactionProbe.main",
        )
        missing = [marker for marker in required_output if marker not in output]
        if missing:
            fail(f"Logback output lost required diagnostic marker {missing[0]!r}")

    print("unifi Logback redaction: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
