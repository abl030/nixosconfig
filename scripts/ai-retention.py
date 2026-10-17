"""Prune AI agent content older than N days, archiving numeric usage first.

Claude Code, Codex and Hermes keep full transcripts (prompts, tool output,
file contents) on disk. This keeps only the last N days of content, and before
deleting anything appends numeric-only usage rows (timestamps, models, token
counts, limit readings) to ~/.local/state/ai-usage/*.jsonl so usage history
survives. See docs/wiki/claude-code/usage-limit-ledger.md.
"""

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import time

HOME = os.path.expanduser("~")
LEDGER = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "ai-usage")


def log(msg):
    print(msg, flush=True)


def jsonl(path):
    with open(path, errors="ignore") as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def claude_rows(path):
    sub = "/subagents/" in path
    for e in jsonl(path):
        if e.get("type") != "assistant":
            continue
        m = e.get("message") or {}
        u = m.get("usage")
        if not u or m.get("model") in (None, "<synthetic>"):
            continue
        cc = u.get("cache_creation") or {}
        yield {
            "ts": e.get("timestamp"), "model": m.get("model"), "id": m.get("id"), "req": e.get("requestId"),
            "sid": e.get("sessionId"), "sub": sub or bool(e.get("isSidechain")),
            "inp": u.get("input_tokens", 0), "cr": u.get("cache_read_input_tokens", 0),
            "w5": cc.get("ephemeral_5m_input_tokens", 0 if cc else u.get("cache_creation_input_tokens", 0)),
            "w1": cc.get("ephemeral_1h_input_tokens", 0), "out": u.get("output_tokens", 0),
        }


def codex_rows(path):
    model = None
    sid = os.path.basename(path)
    for e in jsonl(path):
        p = e.get("payload") or {}
        if e.get("type") == "turn_context":
            model = p.get("model") or model
            continue
        if p.get("type") != "token_count":
            continue
        info = p.get("info") or {}
        rl = p.get("rate_limits") or {}
        win = {}
        for slot in ("primary", "secondary"):
            w = rl.get(slot)
            if w and w.get("window_minutes"):
                win[str(w["window_minutes"])] = [w.get("used_percent"), w.get("resets_at")]
        lu = info.get("last_token_usage") or {}
        yield {
            "ts": e.get("timestamp"), "model": model, "sid": sid, "plan": rl.get("plan_type"), "win": win,
            "total": (info.get("total_token_usage") or {}).get("total_tokens"),
            "inp": lu.get("input_tokens", 0), "cached": lu.get("cached_input_tokens", 0),
            "out": lu.get("output_tokens", 0), "rsn": lu.get("reasoning_output_tokens", 0),
        }


class Ledger:
    def __init__(self, dry):
        self.dry = dry
        os.makedirs(LEDGER, mode=0o700, exist_ok=True)
        self.state_path = os.path.join(LEDGER, "archived.json")
        try:
            self.state = json.load(open(self.state_path))
        except (OSError, ValueError):
            self.state = {}

    def archive(self, kind, path, rows):
        key = f"{kind}:{path}"
        mtime = os.path.getmtime(path)
        if self.state.get(key) == mtime:
            return 0
        n = 0
        if not self.dry:
            with open(os.path.join(LEDGER, f"{kind}-calls.jsonl"), "a") as out:
                for r in rows:
                    out.write(json.dumps(r, separators=(",", ":")) + "\n")
                    n += 1
            self.state[key] = mtime
        return n

    def save(self):
        if self.dry:
            return
        live = {k: v for k, v in self.state.items() if k.startswith("hermes:") or os.path.exists(k.split(":", 1)[1])}
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(live, fh)
        os.replace(tmp, self.state_path)


def newest_mtime(root):
    newest = os.path.getmtime(root)
    for dp, _, fs in os.walk(root):
        for f in fs:
            try:
                newest = max(newest, os.lstat(os.path.join(dp, f)).st_mtime)
            except OSError:
                pass
    return newest


def remove(path, dry, stats):
    try:
        size = os.lstat(path).st_size if not os.path.isdir(path) else sum(
            os.lstat(os.path.join(dp, f)).st_size for dp, _, fs in os.walk(path) for f in fs)
    except OSError:
        size = 0
    stats["bytes"] += size
    stats["items"] += 1
    if dry:
        return
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path, ignore_errors=True)
    else:
        try:
            os.remove(path)
        except OSError:
            pass


def prune_empty_dirs(root, dry):
    if dry or not os.path.isdir(root):
        return
    for dp, _, _ in os.walk(root, topdown=False):
        if dp != root and not os.listdir(dp):
            os.rmdir(dp)


def trim_history(path, field, scale, cutoff, dry):
    """Drop prompt-history lines older than cutoff; keep lines without a parseable time."""
    if not os.path.exists(path):
        return 0
    keep, dropped = [], 0
    with open(path, errors="ignore") as fh:
        for line in fh:
            try:
                t = float(json.loads(line).get(field)) / scale
            except (ValueError, TypeError, AttributeError):
                keep.append(line)
                continue
            if t < cutoff:
                dropped += 1
            else:
                keep.append(line)
    if dropped and not dry:
        tmp = path + ".ai-retention.tmp"
        with open(tmp, "w") as fh:
            fh.writelines(keep)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    return dropped


def hermes(ledger, days, cutoff, dry):
    db = os.path.join(HOME, ".hermes/state.db")
    if not os.path.exists(db) or shutil.which("hermes") is None:
        return
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=30)
    rows = con.execute(
        "select u.session_id, u.model, u.billing_provider, u.task, u.api_call_count, u.input_tokens, u.output_tokens,"
        " u.cache_read_tokens, u.cache_write_tokens, u.reasoning_tokens, u.first_seen, u.last_seen"
        " from session_model_usage u join sessions s on s.id = u.session_id"
        " where coalesce(s.ended_at, s.last_activity_at, s.started_at) < ?", (cutoff,)).fetchall()
    con.close()
    new = [r for r in rows if f"hermes:{r[0]}:{r[1]}:{r[3]}" not in ledger.state]
    if not dry:
        with open(os.path.join(LEDGER, "hermes-calls.jsonl"), "a") as out:
            for r in new:
                out.write(json.dumps(dict(zip(
                    ["sid", "model", "provider", "task", "calls", "inp", "out", "cr", "cw", "rsn", "first", "last"], r)),
                    separators=(",", ":")) + "\n")
                ledger.state[f"hermes:{r[0]}:{r[1]}:{r[3]}"] = 1
    log(f"hermes: archived {len(new)} usage rows")
    cmd = ["hermes", "sessions", "prune", "--older-than", str(days), "--include-archived", "--yes"]
    if dry:
        cmd = ["hermes", "sessions", "prune", "--older-than", str(days), "--include-archived", "--dry-run"]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    log(f"hermes: prune exit {res.returncode}: " + (res.stdout.strip().splitlines() or [""])[-1][:200])
    if not dry and res.returncode == 0:
        # Reclaims freed pages (VACUUM). Refuses while the gateway holds the DB; that is expected.
        opt = subprocess.run(["hermes", "sessions", "optimize"], capture_output=True, text=True, timeout=3600)
        log(f"hermes: optimize exit {opt.returncode}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    os.umask(0o077)
    now = time.time()
    cutoff = now - a.days * 86400
    early = now - (a.days - 3) * 86400  # Claude self-deletes transcripts at 30d; archive them first
    led = Ledger(a.dry_run)
    stats = {"items": 0, "bytes": 0}
    rows = {"claude": 0, "codex": 0}

    # Claude transcripts: archive usage ahead of Claude's own cleanup. Never touch */memory/.
    for root in (os.path.join(HOME, ".claude/projects"), os.path.join(HOME, ".claude/jobs")):
        for dp, _, fs in os.walk(root):
            if "/memory" in dp:
                continue
            for f in fs:
                p = os.path.join(dp, f)
                if f.endswith(".jsonl") and os.path.getmtime(p) < early:
                    rows["claude"] += led.archive("claude", p, claude_rows(p))

    # Claude background jobs: whole job dirs, judged by their newest file.
    jobs = os.path.join(HOME, ".claude/jobs")
    if os.path.isdir(jobs):
        for name in os.listdir(jobs):
            d = os.path.join(jobs, name)
            if os.path.isdir(d) and not os.path.islink(d) and newest_mtime(d) < cutoff:
                remove(d, a.dry_run, stats)

    # Codex rollouts.
    for root in (os.path.join(HOME, ".codex/sessions"), os.path.join(HOME, ".codex/archived_sessions")):
        for dp, _, fs in os.walk(root):
            for f in fs:
                p = os.path.join(dp, f)
                if f.endswith(".jsonl") and os.path.getmtime(p) < cutoff:
                    rows["codex"] += led.archive("codex", p, codex_rows(p))
                    remove(p, a.dry_run, stats)
        prune_empty_dirs(root, a.dry_run)

    hist = trim_history(os.path.join(HOME, ".claude/history.jsonl"), "timestamp", 1000, cutoff, a.dry_run)
    hist += trim_history(os.path.join(HOME, ".codex/history.jsonl"), "ts", 1, cutoff, a.dry_run)

    hlogs = os.path.join(HOME, ".hermes/logs")
    if os.path.isdir(hlogs):
        for dp, _, fs in os.walk(hlogs):
            for f in fs:
                p = os.path.join(dp, f)
                if os.path.getmtime(p) < cutoff:
                    remove(p, a.dry_run, stats)

    led.save()
    log(f"{'dry-run: would remove' if a.dry_run else 'removed'} {stats['items']} items, {stats['bytes'] / 1e9:.2f} GB;"
        f" archived usage rows claude={rows['claude']} codex={rows['codex']}; prompt-history lines dropped={hist}")
    hermes(led, a.days, cutoff, a.dry_run)
    led.save()


if __name__ == "__main__":
    main()
