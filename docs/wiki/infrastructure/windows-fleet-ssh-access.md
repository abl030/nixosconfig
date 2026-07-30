# Windows fleet SSH access (`tools/windows/Setup-FleetSSH.ps1`)

**Status:** working, verified end-to-end 2026-07-30
**Script:** `tools/windows/Setup-FleetSSH.ps1`
**First real use:** `CULLENW-POS4` (Cullen site POS terminal, `192.168.100.67`)

---

## ⚡ The one-liner

**Elevated PowerShell**, at the box, nothing to download or save.

**Pinned (preferred).** A commit SHA in the raw URL is immutable — the content
cannot be changed under you, even by someone who can write to the repo:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm 'https://raw.githubusercontent.com/abl030/nixosconfig/a247732b8023512e4a8151d2bae80c6ac6c58bac/tools/windows/Setup-FleetSSH.ps1')
```

SHA-256 of the script at that commit:
`d8194e522ba69213a6abff8935ecf473be4f39e34a62b9d34bcc40b73c60eb1d`

Older Windows note: `CW-TS01` (Server 2016, build 14393) hung on the first
attempt. The OpenSSH Windows *feature* does not exist before build 17763, so the
script now checks the build first and installs Microsoft's signed MSI directly
instead -- verifying its Authenticode signature before running it. Pass
`-NoMsiDownload` to refuse that and get manual instructions.

**Floating.** Always the newest version, but trusts whatever `master` holds at the
moment you paste it:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm 'https://raw.githubusercontent.com/abl030/nixosconfig/master/tools/windows/Setup-FleetSSH.ps1')
```

Re-pin after changing the script:
`git rev-parse origin/master` — then swap the SHA above.

### What one paste does

It runs **in memory**, which is not subject to execution policy or code signing,
so it works on locked-down boxes where Group Policy silently overrides
`-ExecutionPolicy Bypass`. In one go it will:

1. get OpenSSH Server installed if missing — the Windows feature where that is
   possible, otherwise Microsoft's official signed MSI, Authenticode-verified
   before it runs;
2. authorise the fleet key with correct ACLs;
3. **open port 22**, re-enabling rules a previous close disabled and ensuring its
   own port-keyed rule;
4. start `sshd` **for this session only**;
5. self-test a real key login and tell you whether it actually worked.

`Tls12` is load-bearing: older Windows (.NET 4.6 era, e.g. LTSB 2016) defaults to
TLS 1.0 and cannot reach GitHub at all without it.

### It does not stay open

`sshd` is set to **Manual**, not Automatic — it runs now and is gone after a
reboot, so a box you forget about closes itself. `-Persist` for a machine that
should keep SSH. To pass any argument use the script-block form, because `iex`
cannot take arguments:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/abl030/nixosconfig/a247732b8023512e4a8151d2bae80c6ac6c58bac/tools/windows/Setup-FleetSSH.ps1'))) -TargetUser shopfloor -Persist
```

### Close it when you are done

```powershell
Stop-Service sshd -Force; Set-Service sshd -StartupType Disabled; Get-NetFirewallRule -DisplayName '*SSH*' | Disable-NetFirewallRule; Get-Service sshd
```

Expect `Stopped`. Nothing listens on 22 and the inbound rules are off. The
authorised key stays but is inert; re-running the one-liner re-opens everything.

### Fully revoke, rather than just close

```powershell
Set-Content 'C:\ProgramData\ssh\administrators_authorized_keys' '' ; Remove-Item "$env:USERPROFILE\.ssh\authorized_keys" -Force -ErrorAction SilentlyContinue
```

### The trade-off

`iex (irm ...)` runs code from the internet as Administrator. Pinning the commit
removes the "changed under you" risk but not the "you are executing a remote
script as admin" one. Accepted deliberately: it is our own repo over HTTPS and
the convenience at a customer site is the entire point.

> Mirrored read-only to
> `github.com/abl030/nixosconfig/blob/master/docs/wiki/infrastructure/windows-fleet-ssh-access.md`
> so this can be copied from a phone while standing at the machine.

---

## Proven end to end

Validated against a throwaway VM clone, deliberately made hostile: OpenSSH
capability removed entirely, host renamed (`TILL-07`), a **different**
passwordless local admin (`shopfloor`) that had never logged in, and driven
through the hypervisor guest agent as SYSTEM rather than from a console.

Final result — one paste, from a box doc1 had never touched:

```
[ok] sshd is Running / Manual  (this session only -- gone after a reboot)
[ok] Created port rule 'Fleet SSH (TCP 22 inbound)' scoped to LAN + tailnet
[ok] C:\ProgramData\ssh\administrators_authorized_keys  (KEY ADDED)
[ok] Key authentication WORKS. Remote whoami: till-07\shopfloor
DONE and VERIFIED.
```

then from doc1: `ssh shopfloor@<ip>` → `till-07\shopfloor`.

Five real defects were found and fixed by that exercise, none of which a code
review would plausibly have caught:

1. **`$env:USERNAME` is the machine account under SYSTEM.** Bootstrapping via a
   scheduled task, RMM agent or guest agent targeted `HOST$`, which cannot exist.
   Now falls back to the console user, then the sole local account.
2. **`Add-WindowsCapability` hangs, it does not fail,** when the box has no route
   to Windows Update. Now bounded, and the MSI takes over.
3. **The profile path was invented.** Under SYSTEM `$env:USERPROFILE` is the
   systemprofile, yielding `C:\Windows\system32\config\<user>`. Worse,
   pre-creating `C:\Users\<user>` makes Windows create `<user>.<HOST>` at first
   logon. No profile now means no per-user key file.
4. **A firewall rule named `*SSH*` is not an open port.** Windows rules are often
   program-scoped; one pointing at an `sshd.exe` that no longer exists (feature
   install removed, MSI install added at a different path) enumerates perfectly
   and permits nothing. Observed live: `sshd` Running, rule enabled, port 22
   refusing. The script now always ensures its own **port-keyed** rule.
5. **Profile-less cleanup crashed a successful run.** `Test-Path ''` threw inside
   the `finally` block after a passing self-test, losing the summary and exiting
   non-zero.

Two more came from the first real run on `CW-TS01`, which hung outright:

6. **`Stop-Job` blocks, so the timeout did not save us.** The timer fired, but a
   job wedged inside DISM never answers `Stop-Job`, which then waits forever for
   the runspace to die — the script hung anyway, just after the timeout instead
   of before it. Only a *process* can be killed reliably, so the feature install
   now uses `Start-Process` + `WaitForExit` + `Kill()`, the same pattern already
   used for the loopback self-test.
7. **The call should never have been made.** The OpenSSH feature does not exist
   before build **17763** (1809 / Server 2019). `CW-TS01` is Server 2016, build
   14393 — four guaranteed-futile minutes in front of someone standing at the
   machine. The build is now checked first.

---

## Reference

The fleet key's private half lives only on doc1, so this widens what doc1 can
reach without giving any other host a new path.

**Switches**

| | |
|---|---|
| `-TargetUser <name>` | Account to authorise. Defaults to the current user; under SYSTEM that is the machine account, so it falls back to the console user, then the sole local account. |
| `-PublicKey <str>` | Override the embedded fleet key. |
| `-Persist` | Leave `sshd` Automatic instead of session-only. |
| `-CapTimeoutSec <n>` | Wait before abandoning the Windows feature install (default 240). Skipped entirely below build 17763. |
| `-NoMsiDownload` | Refuse the MSI fallback; print manual instructions instead. |
| `-HardenPasswordAuth` | After a **passing** self-test, also set `PasswordAuthentication no`. Refuses otherwise, so it cannot lock you out. |
| `-AllowBlankPasswordAuth` | Only if the self-test is actively refused on a blank-password account. Relaxes `LimitBlankPasswordUse` machine-wide. |
| `-AnyRemote` | Do not scope the firewall rule to LAN + tailnet. |

Exit codes: `0` success, `1` error, `2` OpenSSH could not be installed by any
route (needs a human).

Idempotent. Existing authorised keys are preserved, never replaced, and the
original `sshd_config` is kept at `sshd_config.fleet-backup`.

Running from a local copy instead of the one-liner:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-FleetSSH.ps1
```

…except where Group Policy pins the execution policy, in which case only the
in-memory form works:

```powershell
& ([scriptblock]::Create((Get-Content .\Setup-FleetSSH.ps1 -Raw)))
```

## Windows gotchas this script encodes

Each of these was a real bug caught by testing against a live Windows box, not theory.
Preserve them if you refactor:

- **One-element array unwrapping.** `$lines = Read-KeyLines $p` unwraps a
  single-element array to a bare *string*, so `$lines += $key` concatenates the new
  key onto the end of the existing line — destroying the existing key and registering
  neither. Always `@(...)` the result.
- **`$ErrorActionPreference='Stop'` + native stderr.** PowerShell 5.1 promotes any
  native stderr line reaching the pipeline into a *terminating* error. ssh's harmless
  "Permanently added ... to the list of known hosts" therefore aborts the self-test.
  Relax to `Continue` around native calls and judge on `$LASTEXITCODE`.
- **`Start-Process -PassThru` loses `.ExitCode`.** Reads back empty once the process
  exits unless you touch `$proc.Handle` first to cache the native handle.
- **`& ssh` can hang forever** when spawned from a Session-0 service context (i.e.
  when the script is itself launched over SSH or from a scheduled task). Use
  `Start-Process` with redirects and a hard `WaitForExit(ms)` timeout so the script
  can never hang on a machine someone is standing at.
- **`Stop-Job` blocks on a job stuck in a native call.** A `Wait-Job -Timeout`
  that expires is useless if the `Stop-Job` after it then hangs forever. Use a
  separate process and `Kill()` it; never a job, for anything that can wedge.
- **BOM.** A UTF-8 BOM corrupts the first line of `authorized_keys` and sshd silently
  ignores that key. Always write with `UTF8Encoding($false)`.
- **`Match` block scoping.** Directives appended *after* a `Match` block belong to
  that block, not the global section, and silently do nothing.
- **Locale.** `Administrators`/`SYSTEM` are localised; use well-known SIDs
  (`S-1-5-32-544`, `S-1-5-18`) for all ACL and group work.

## Blank passwords

Windows' `LimitBlankPasswordUse` (default `1`) restricts blank-password accounts to
console logon, which *can* block the S4U network logon OpenSSH uses for public-key
auth. The script detects a blank password and, if the self-test is actively refused,
offers two options: set a password (`net user <user> *` — key auth never prompts for
it), or re-run with `-AllowBlankPasswordAuth`.

**On `CULLENW-POS4` this did not bite** — the account has no password
(`PasswordRequired = False`, never set), `LimitBlankPasswordUse` remained `1`, and
key auth worked regardless. Do not pre-emptively relax that policy; it permits
blank-password *network* logon machine-wide.

## Verifying

From doc1:

```bash
ssh Idealpos@192.168.100.67   # -> cullenw-pos4\idealpos
```

## Current state of CULLENW-POS4

**SSH is CLOSED as of 2026-07-30.** `sshd` is Stopped + Disabled and the inbound
rules are disabled, so nothing listens on 22. The fleet key is still authorised
but inert. Re-open with the one-liner at the top of this page.

Closing it does not strand anyone: the box has TeamViewer installed and console
autologin as `Idealpos`, so there is always a way back in to run the one-liner.

## Notes on reach

Tailscale needed no change for the Cullen site: the
`{"src":["doc1"],"dst":["*"],"ip":["*"]}` grant in `tailscale/acl.hujson` covers
subnet-routed CIDRs, not just tailnet nodes, so doc1 already reached
`192.168.100.0/24` via the laptop's advertised route. Confirm on the wire
(`ping`, port probe) rather than reading the policy — the wildcard's scope is easy
to misread. See `docs/wiki/infrastructure/tailscale-acl.md`.

## When to revisit

- Windows older than build 17763 has no OpenSSH feature at all; the script detects
  this and installs the signed MSI instead, so it no longer needs a human. Both
  `CULLENW-POS4` (Win10 LTSB 2016) and `CW-TS01` (Server 2016) are build 14393.
- The MSI fallback pins a known-good build if `api.github.com` is unreachable.
  Refresh that pin occasionally — see `Install-OpenSSHFromMsi` in the script.
- The script deliberately leaves `PasswordAuthentication` alone by default. On a
  box we own, consider `-HardenPasswordAuth` (it refuses unless the self-test passed,
  so it cannot lock you out).
