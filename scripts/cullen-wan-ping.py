#!/usr/bin/env python3
"""Outward ping logger for Cullen's internet links (runs on wsl, on site).

One `ping -D -O -n -i 1 -W 1` per target (unprivileged ICMP sockets). Each probe becomes a line
"<epoch>\\t<rtt ms>" or "<epoch>\\t-" (no reply within 1 s) in
<data-dir>/<YYYY-MM-DD>/<target>.tsv (local date). At each day rollover, previous days
are gzipped and days older than --keep-days removed. A ping process that exits is
restarted. Reports: cullen-assistant scripts/wan latency. See
docs/wiki/services/cullen-wan-usage.md.
"""
import argparse, datetime, gzip, os, re, shutil, subprocess, threading, time

ap = argparse.ArgumentParser()
ap.add_argument('--data-dir', required=True)
ap.add_argument('--ping', default='ping')
ap.add_argument('--keep-days', type=int, default=90)
ap.add_argument('targets', nargs='+')
a = ap.parse_args()
lock = threading.Lock()
files = {}
RX = re.compile(r'^\[(\d+\.\d+)\] (.*)$')


def write(target, ts, val):
    day = datetime.date.fromtimestamp(ts).isoformat()
    with lock:
        f = files.get(target)
        if not f or f[0] != day:
            if f:
                f[1].close()
            d = os.path.join(a.data_dir, day)
            os.makedirs(d, exist_ok=True)
            files[target] = f = (day, open(os.path.join(d, f'{target}.tsv'), 'a', buffering=1))
        f[1].write(f'{ts:.3f}\t{val}\n')


def prober(target):
    while True:
        p = subprocess.Popen([a.ping, '-D', '-O', '-n', '-i', '1', '-W', '1', target],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in p.stdout:
            m = RX.match(line.strip())
            if not m:
                continue
            ts, rest = float(m.group(1)), m.group(2)
            if 'no answer yet' in rest:
                write(target, ts, '-')
            elif (r := re.search(r'time=([\d.]+)', rest)):
                write(target, ts, r.group(1))
        p.wait()
        print(f'ping {target} exited {p.returncode}; restarting', flush=True)
        time.sleep(5)


def housekeeping():
    today = datetime.date.today()
    for name in sorted(os.listdir(a.data_dir)):
        try:
            day = datetime.date.fromisoformat(name)
        except ValueError:
            continue
        path = os.path.join(a.data_dir, name)
        if (today - day).days > a.keep_days:
            shutil.rmtree(path)
        elif day < today:
            for fn in os.listdir(path):
                if fn.endswith('.tsv'):
                    src = os.path.join(path, fn)
                    with open(src, 'rb') as i, gzip.open(src + '.gz.tmp', 'wb') as o:
                        shutil.copyfileobj(i, o)
                    os.replace(src + '.gz.tmp', src + '.gz')
                    os.remove(src)


os.makedirs(a.data_dir, exist_ok=True)
for t in a.targets:
    threading.Thread(target=prober, args=(t,), daemon=True).start()
print(f'pinging {", ".join(a.targets)}', flush=True)
last = None
while True:
    if datetime.date.today() != last:
        time.sleep(30)  # let the probers roll over to the new day's files first
        housekeeping()
        last = datetime.date.today()
    time.sleep(60)
