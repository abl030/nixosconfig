#!/usr/bin/env python3
"""Replay the generated URI guard on renderer and Java-properties encodings."""
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
lines = [line.strip() for line in source.splitlines() if line.strip().startswith('grep ') and 'mongo\\.uri=' in line]
assert len(lines) == 1
command = shlex.split(lines[0].split(' 2>/dev/null')[0])
assert command[0] == 'grep'
uri = 'mongodb://FixtureUser:FixturePassword@127.0.0.1:27117/ace?authSource=admin'
cases = [('renderer', uri, True), ('java-properties', uri.replace(':', '\\:'), True)]
for name, value in [('wrong-port', uri.replace('27117', '27118')),
                    ('wildcard', uri.replace('127.0.0.1', '0.0.0.0')),
                    ('off-host', uri.replace('127.0.0.1', '192.168.1.35')),
                    ('no-auth', 'mongodb://127.0.0.1:27117/ace'),
                    ('wrong-scheme', uri.replace('mongodb:', 'http:'))]:
    cases.extend([(name, value, False), (name+'-escaped', value.replace(':', '\\:'), False)])
with tempfile.TemporaryDirectory(prefix='unifi-properties-guard-') as temp:
    path = Path(temp) / 'system.properties'
    for name, value, expected in cases:
        path.write_text('db.mongo.uri='+value+'\n')
        result = subprocess.run(command[:-1]+[str(path)], capture_output=True)
        assert (result.returncode == 0) == expected, name
        print('PASS', name)
