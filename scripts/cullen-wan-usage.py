#!/usr/bin/env python3
"""Cullen SonicWall per-port traffic counters over SNMP, for monthly WAN usage.

collect  one SNMP v2c GET of sysUpTime + every port's ifName, ifHCIn/OutOctets and
         ifOperStatus; one row per port into <data-dir>/usage.sqlite.
backup   consistent SQLite copy into --backup-dir (atomic replace).
check    fail unless a sample landed within --max-age seconds.

The community comes from a dotenv credential (SNMP_COMMUNITY=...) and is handed to
net-snmp through a private snmp.conf, never argv. Reports: cullen-assistant
scripts/wan-usage. See docs/wiki/services/cullen-wan-usage.md.
"""
import argparse, os, sqlite3, subprocess, sys, tempfile, time

HOST = '192.168.100.14'
PORTS = range(1, 11)  # ifIndex 1..10 = X0..X7, W0, U0 on the TZ 370W
SCHEMA = '''CREATE TABLE IF NOT EXISTS samples(
  ts REAL NOT NULL, uptime_cs INTEGER NOT NULL, ifindex INTEGER NOT NULL, ifname TEXT NOT NULL,
  in_octets INTEGER NOT NULL, out_octets INTEGER NOT NULL, oper INTEGER NOT NULL,
  PRIMARY KEY(ts, ifindex));'''


def db(path):
    con = sqlite3.connect(path, timeout=30)
    con.execute('PRAGMA journal_mode=WAL')
    con.execute(SCHEMA)
    return con


def collect(a):
    env = dict(l.strip().split('=', 1) for l in open(a.credential) if '=' in l)
    oids = ['1.3.6.1.2.1.1.3.0']
    for i in PORTS:
        oids += [f'1.3.6.1.2.1.31.1.1.1.1.{i}', f'1.3.6.1.2.1.31.1.1.1.6.{i}',
                 f'1.3.6.1.2.1.31.1.1.1.10.{i}', f'1.3.6.1.2.1.2.2.1.8.{i}']
    with tempfile.TemporaryDirectory() as td:
        with open(os.path.join(td, 'snmp.conf'), 'w') as f:
            os.fchmod(f.fileno(), 0o600)
            f.write(f"defVersion 2c\ndefCommunity {env['SNMP_COMMUNITY']}\nmibs :\n")
        r = subprocess.run([a.snmpget, '-t', '5', '-r', '2', '-Oqvt', HOST, *oids],
                           env={'SNMPCONFPATH': td, 'PATH': '/nonexistent'}, capture_output=True, text=True)
    vals = r.stdout.split('\n')
    ts = time.time()
    if r.returncode != 0 or len([v for v in vals if v]) != len(oids):
        print(f'CULLEN_WAN_USAGE_FAILED snmpget rc={r.returncode}: {r.stderr.strip()[:200]}', file=sys.stderr)
        sys.exit(1)
    uptime = int(vals[0])
    rows = []
    for n, i in enumerate(PORTS):
        name, rx, tx, oper = vals[1 + 4 * n: 5 + 4 * n]
        rows.append((ts, uptime, i, name.strip('"'), int(rx), int(tx), int(oper)))
    with db(a.db) as con:
        con.executemany('INSERT INTO samples VALUES (?,?,?,?,?,?,?)', rows)
    print(f'collected {len(rows)} ports, uptime {uptime / 8640000:.1f} d')


def backup(a):
    os.makedirs(a.backup_dir, exist_ok=True)
    dst = os.path.join(a.backup_dir, 'usage.sqlite')
    tmp = dst + '.tmp'
    src = db(a.db)
    out = sqlite3.connect(tmp)
    src.backup(out)
    n = out.execute('SELECT count(*) FROM samples').fetchone()[0]
    out.close(); src.close()
    os.replace(tmp, dst)
    print(f'backed up {n} rows to {dst}')


def check(a):
    con = sqlite3.connect(f'file:{a.db}?mode=ro', uri=True)
    last = con.execute('SELECT max(ts) FROM samples').fetchone()[0]
    age = time.time() - (last or 0)
    print(f'last sample {age:.0f} s ago')
    sys.exit(0 if age <= a.max_age else 1)


ap = argparse.ArgumentParser()
ap.add_argument('cmd', choices=['collect', 'backup', 'check'])
ap.add_argument('--data-dir', required=True)
ap.add_argument('--credential')
ap.add_argument('--snmpget', default='snmpget')
ap.add_argument('--backup-dir')
ap.add_argument('--max-age', type=int, default=86400)
a = ap.parse_args()
a.db = os.path.join(a.data_dir, 'usage.sqlite')
{'collect': collect, 'backup': backup, 'check': check}[a.cmd](a)
