#!/usr/bin/env python3
"""Cullen SonicWall per-port counters over SNMP: usage, 10 s throughput and link flaps.

run      loop: every --interval s one SNMP v2c GET of sysUpTime + every port's ifName,
         ifHCIn/OutOctets, ifOperStatus and ifLastChange; one row per port into
         <data-dir>/usage.sqlite. ifLastChange catches link flaps shorter than the
         interval (sysUpTime ticks coarsely on the TZ 370W, so ~±15 s).
collect  a single sample (same as one loop iteration).
backup   thin rows older than --keep-days to one per minute, then a consistent
         SQLite copy into --backup-dir (atomic replace).
check    fail unless a sample landed within --max-age seconds.

The community comes from a dotenv credential (SNMP_COMMUNITY=...) and reaches
net-snmp through a private snmp.conf, never argv. Reports: cullen-assistant
scripts/wan. See docs/wiki/services/cullen-wan-usage.md.
"""
import argparse, os, sqlite3, subprocess, sys, tempfile, time

HOST = '192.168.100.14'
PORTS = range(1, 11)  # ifIndex 1..10 = X0..X7, W0, U0 on the TZ 370W
FIELDS = 5  # ifName, in, out, oper, lastchange
SCHEMA = '''CREATE TABLE IF NOT EXISTS samples(
  ts REAL NOT NULL, uptime_cs INTEGER NOT NULL, ifindex INTEGER NOT NULL, ifname TEXT NOT NULL,
  in_octets INTEGER NOT NULL, out_octets INTEGER NOT NULL, oper INTEGER NOT NULL,
  last_change_cs INTEGER,
  PRIMARY KEY(ts, ifindex));'''


def db(path):
    con = sqlite3.connect(path, timeout=30)
    # Rollback journal, not WAL: read-only consumers (other users, the deep probe)
    # cannot create the -shm file in the service-owned directory.
    con.execute('PRAGMA journal_mode=DELETE')
    con.execute(SCHEMA)
    cols = [r[1] for r in con.execute('PRAGMA table_info(samples)')]
    if 'last_change_cs' not in cols:  # rows from the 1-minute v1 collector
        con.execute('ALTER TABLE samples ADD COLUMN last_change_cs INTEGER')
    con.commit()
    return con


class Poller:
    def __init__(self, a):
        env = dict(l.strip().split('=', 1) for l in open(a.credential) if '=' in l)
        self.snmpget = a.snmpget
        self.td = tempfile.TemporaryDirectory()
        with open(os.path.join(self.td.name, 'snmp.conf'), 'w') as f:
            os.fchmod(f.fileno(), 0o600)
            f.write(f"defVersion 2c\ndefCommunity {env['SNMP_COMMUNITY']}\nmibs :\n")
        self.oids = ['1.3.6.1.2.1.1.3.0']
        for i in PORTS:
            self.oids += [f'1.3.6.1.2.1.31.1.1.1.1.{i}', f'1.3.6.1.2.1.31.1.1.1.6.{i}',
                          f'1.3.6.1.2.1.31.1.1.1.10.{i}', f'1.3.6.1.2.1.2.2.1.8.{i}',
                          f'1.3.6.1.2.1.2.2.1.9.{i}']

    def sample(self):
        r = subprocess.run([self.snmpget, '-t', '3', '-r', '1', '-Oqvt', HOST, *self.oids],
                           env={'SNMPCONFPATH': self.td.name, 'PATH': '/nonexistent'},
                           capture_output=True, text=True)
        ts = time.time()
        vals = r.stdout.split('\n')
        if r.returncode != 0 or len([v for v in vals if v]) != len(self.oids):
            raise RuntimeError(f'snmpget rc={r.returncode}: {r.stderr.strip()[:200]}')
        uptime = int(vals[0])
        rows = []
        for n, i in enumerate(PORTS):
            name, rx, tx, oper, lc = vals[1 + FIELDS * n: 1 + FIELDS * (n + 1)]
            rows.append((ts, uptime, i, name.strip('"'), int(rx), int(tx), int(oper), int(lc)))
        return rows


INSERT = 'INSERT INTO samples VALUES (?,?,?,?,?,?,?,?)'


def collect(a):
    rows = Poller(a).sample()
    con = db(a.db)
    with con:
        con.executemany(INSERT, rows)
    print(f'collected {len(rows)} ports, uptime {rows[0][1] / 8640000:.1f} d')


def run(a):
    poller, con = Poller(a), db(a.db)
    failing, n = False, 0
    nxt = (time.time() // a.interval + 1) * a.interval
    while True:
        time.sleep(max(0, nxt - time.time()))
        nxt += a.interval
        if nxt < time.time():  # fell behind (suspend, long timeout): realign
            nxt = (time.time() // a.interval + 1) * a.interval
        try:
            rows = poller.sample()
        except RuntimeError as e:
            if not failing:  # one line per outage, not per poll
                print(f'CULLEN_WAN_USAGE_GAP {e}', file=sys.stderr, flush=True)
            failing = True
            continue
        with con:
            con.executemany(INSERT, rows)
        n += 1
        if failing or n == 1:
            print(f'sampling ({len(rows)} ports, uptime {rows[0][1] / 8640000:.1f} d)', flush=True)
        failing = False


def backup(a):
    con = db(a.db)
    cutoff = time.time() - a.keep_days * 86400
    with con:  # keep the first sample of each minute; counters are cumulative, so sums stay exact
        thinned = con.execute('DELETE FROM samples WHERE ts < ? AND CAST(ts AS INTEGER) % 60 >= ?',
                              (cutoff, a.interval)).rowcount
    os.makedirs(a.backup_dir, exist_ok=True)
    dst = os.path.join(a.backup_dir, 'usage.sqlite')
    tmp = dst + '.tmp'
    out = sqlite3.connect(tmp)
    con.backup(out)
    n = out.execute('SELECT count(*) FROM samples').fetchone()[0]
    out.close(); con.close()
    os.replace(tmp, dst)
    print(f'thinned {thinned} rows older than {a.keep_days} d; backed up {n} rows to {dst}')


def check(a):
    con = sqlite3.connect(f'file:{a.db}?mode=ro', uri=True)
    last = con.execute('SELECT max(ts) FROM samples').fetchone()[0]
    age = time.time() - (last or 0)
    print(f'last sample {age:.0f} s ago')
    sys.exit(0 if age <= a.max_age else 1)


ap = argparse.ArgumentParser()
ap.add_argument('cmd', choices=['run', 'collect', 'backup', 'check'])
ap.add_argument('--data-dir', required=True)
ap.add_argument('--credential')
ap.add_argument('--snmpget', default='snmpget')
ap.add_argument('--interval', type=int, default=10)
ap.add_argument('--keep-days', type=int, default=35)
ap.add_argument('--backup-dir')
ap.add_argument('--max-age', type=int, default=86400)
a = ap.parse_args()
a.db = os.path.join(a.data_dir, 'usage.sqlite')
{'run': run, 'collect': collect, 'backup': backup, 'check': check}[a.cmd](a)
