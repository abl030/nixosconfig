# Durable tmux under `StopIdleSessionSec` (user@.service-scoped server)

**Date:** 2026-06-28 · **Status:** live on doc1 (deploying via nightly), pattern reusable fleet-wide · **Issue:** [#232](https://github.com/abl030/nixosconfig/issues/232) (host-hardening umbrella, idle-session reap) · **Commit:** `3b273856`

## Symptom

A long-lived tmux server on **doc1** (`proxmox-vm`) kept dying on its own. Attaching showed:

```
❯ tmux a -t 0
[server exited]
```

It correlated with being **AFK** — reliably after ~55 min idle. Observed pattern: it died when the session had been **launched from the phone (Termux/SSH)** and the phone was locked; launching from a desktop terminal that stayed connected (Ghostty) "seemed fine."

This is **not** a crash, not OOM, not a reboot. It's the host-hardening idle-session reaper killing the cgroup the tmux server happened to live in.

## Root cause

`base.nix` sets a fleet-wide idle reap (see [host-hardening-baseline.md](host-hardening-baseline.md) §3):

```nix
services.logind.settings.Login.StopIdleSessionSec = "55min";
```

The smoking gun in the journal:

```
systemd-logind[1277]: Session "8" of user "abl030" is idle, stopping.
systemd[1]: session-8.scope: Killing process 198964 (tmux: server) with signal SIGTERM.
systemd[1]: session-8.scope: Deactivated successfully.
```

The mechanics that make this bite tmux:

1. **A tmux server inherits the systemd login-session scope of whichever client *launches* it** (the `tmux new` / first attach that spawns the server — **not** later attaches). Confirmed live:

   ```
   $ cat /proc/<tmux-server-pid>/cgroup
   0::/user.slice/user-1000.slice/session-9.scope        # ← a login session, reapable
   ```

2. **`StopIdleSessionSec` does not "log you out gracefully" — it force-stops the session *scope unit*.** Stopping `session-<n>.scope` stops its cgroup, i.e. SIGTERM to **every** process inside it, including the tmux server.

3. **`KillUserProcesses=false` does NOT protect against this.** That setting only governs the *graceful last-logout* path (leave leftover processes alone when the final session ends normally). An **explicit session stop** (idle reap, or `loginctl terminate-session`) tears the scope down regardless. This is the subtlety that made the old hardening note wrong — see "Doc correction" below.

### Why this looked client-dependent (Termux vs Ghostty)

Because the server lives in the **launching** session's scope:

- **Launched from Termux** → server is anchored to the phone's SSH session. Lock the phone → no PTY input → that session goes idle → 55 min later logind force-stops the scope → server dies.
- **Launched from Ghostty** (desktop, stays connected/active) → server anchored to a session that rarely goes idle. And if you only *attach* from Termux to a Ghostty-launched server, the phone idling kills just the Termux *client*, not the server.

It's fragile either way: whoever births the server owns its lifetime, and any owning session that idles 55 min takes the server with it.

### Why `linger=true` alone didn't save it

doc1 already had `users.users.abl030.linger = true`. Linger keeps **`user@1000.service` / `user.slice`** alive across logouts — but a tmux started by hand from a shell is in the **session scope**, *not* `user.slice`. Daemonising (tmux double-forks) escapes the controlling terminal but **not** the cgroup. So linger protected a thing the server was never in. Proof that user-manager-launched processes *do* escape:

```
$ systemd-run --user --unit=probe --collect sleep 30
$ cat /proc/<pid>/cgroup
0::/user.slice/user-1000.slice/user@1000.service/app.slice/probe.service   # ← never idle-reaped
```

## The fix

Put the tmux **server** inside `user@1000.service` by starting it from a systemd **user** service. It's then in `user.slice` (not a "session"), so it can never be idle-reaped, and the existing `linger=true` keeps it alive across full disconnects and reboots. doc1 only — `hosts/proxmox-vm/configuration.nix`:

```nix
systemd.user.services.tmux = {
  description = "Durable tmux server (user@.service-scoped; survives idle-session reap)";
  wantedBy = ["default.target"];
  serviceConfig = {
    Type = "forking";
    Environment = "TMUX_TMPDIR=%t";
    ExecStart = "${pkgs.tmux}/bin/tmux new-session -d -s 0";
    ExecStop = "${pkgs.tmux}/bin/tmux kill-server";
    Restart = "on-failure";
  };
};
```

### ⚠️ Gotcha: the unit MUST use the same socket as your interactive shells

tmux's socket path is `$TMUX_TMPDIR/tmux-<uid>/default`. On doc1 the interactive
shells run with `TMUX_TMPDIR=/run/user/1000`, so the live server listens on:

```
$ ss -xlp | grep tmux
… /run/user/1000/tmux-1000/default … ("tmux: server",pid=…)
```

A systemd user service does **not** inherit `TMUX_TMPDIR` (it's not in
`systemctl --user show-environment`), so without help it would default to
`/tmp/tmux-1000/default` — a **different** socket, and `tmux a` would never find
the unit's server. `Environment = "TMUX_TMPDIR=%t"` fixes this: `%t` is the
user-unit runtime dir = `/run/user/1000`, so the unit's socket is exactly
`/run/user/1000/tmux-1000/default`. Plain `tmux attach` / `tmux a -t 0` then find
it transparently. Session is named `0` to preserve the existing `tmux a -t 0`
habit.

### ⚠️ Gotcha: the running server keeps the socket until it dies

After deploy, a server may already own the socket (in the reapable scope). A new
`tmux new-session` just talks to the existing server — it does **not** spawn a
fresh one in `user@.service`. Also, NixOS `switch` installs the user-unit
definition but does **not** auto-start systemd *user* services. So the durable
server actually takes over on the **next reboot** (the unit starts at boot under
the lingering user manager, before any login owns the socket). To force it
sooner: `tmux kill-server` (drops current sessions) then
`systemctl --user start tmux` — a reboot is cleaner.

## Doc correction

[host-hardening-baseline.md](host-hardening-baseline.md) §3 previously claimed:

> "the idle reap drops the *connection* but a detached tmux/mosh session persists; reconnect and reattach."

That is **false** for a tmux/mosh server living in the reaped session's scope —
the force-stop kills it. `KillUserProcesses=false` only guards the
graceful-logout path. A detached server survives the idle reap **only** if it's
in `user@.service` (this unit) or on a different, non-idle session's scope. The
hardening doc has been corrected to point here.

## Verifying

```sh
# Which cgroup is the server in? Want .../user@1000.service/..., NOT session-<n>.scope
for p in $(pgrep -x tmux); do cat /proc/$p/cgroup; done

# Same socket the shells use?
ss -xlp | grep tmux            # → /run/user/1000/tmux-1000/default

# Is the durable unit up (after a reboot)?
systemctl --user status tmux

# Reproduce the reaper (history): the kill shows in the journal as
journalctl -k -u systemd-logind --since -2h | grep -i "is idle, stopping"
```

## When to revisit

- **Other interactive hosts** (`framework`, `epi`) also carry `linger=true` and
  the fleet-wide `StopIdleSessionSec=55min`, so a hand-started tmux there is
  equally reapable. Only doc1 has the durable unit today (it's the phone/Termux
  bastion). Copy `systemd.user.services.tmux` into a host's config to give it the
  same protection.
- If the fleet ever moves `TMUX_TMPDIR` off `/run/user/<uid>`, re-check that
  `%t` still resolves to the shells' socket dir (or switch to an absolute
  `-S /run/user/1000/tmux-default` socket on both the unit and the attach
  command).
- If `StopIdleSessionSec` is removed or raised fleet-wide, this unit is still
  harmless (a boot-time durable server) but no longer load-bearing.
