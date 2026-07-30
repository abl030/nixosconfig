# Windows fleet SSH access (`tools/windows/Setup-FleetSSH.ps1`)

**Status:** working, verified end-to-end 2026-07-30
**Script:** `tools/windows/Setup-FleetSSH.ps1`
**First real use:** `CULLENW-POS4` (Cullen site POS terminal, `192.168.100.67`)

---

## ⚡ The one-liner

**Elevated PowerShell**, at the box, nothing to download or save:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm 'https://raw.githubusercontent.com/abl030/nixosconfig/master/tools/windows/Setup-FleetSSH.ps1')
```

That is the whole loop. It fetches this repo's script from the public GitHub
mirror and runs it **in memory**, which is not subject to execution policy or code
signing — so it works on locked-down boxes where Group Policy silently overrides
`-ExecutionPolicy Bypass`. In one paste it will:

1. install the OpenSSH Server feature if it is missing,
2. authorise the fleet key (`master-fleet-identity`) with correct ACLs,
3. **re-enable any disabled SSH firewall rules** — so a box we closed earlier
   re-opens rather than accumulating duplicate rules,
4. start `sshd` **for this session only**, and
5. self-test a real key login and tell you whether it actually worked.

`Tls12` is load-bearing: older Windows (.NET 4.6 era, e.g. LTSB 2016) still
defaults to TLS 1.0 and simply cannot reach GitHub without it.

### It does not stay open

`sshd` is set to **Manual**, not Automatic. It runs now and is gone after a
reboot, so a box you forget about closes itself. Pass `-Persist` for a machine
that should keep SSH permanently:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/abl030/nixosconfig/master/tools/windows/Setup-FleetSSH.ps1'))) -Persist
```

(Use the `[scriptblock]::Create(...)` form whenever you need to pass arguments —
`iex` cannot take them.)

### Close it when you are done

```powershell
Stop-Service sshd -Force; Set-Service sshd -StartupType Disabled; Get-NetFirewallRule -DisplayName '*SSH*' | Disable-NetFirewallRule; Get-Service sshd
```

Expect `Stopped`. Nothing listens on 22 and the inbound rules are off, so the port
is shut at both layers. The authorised key stays but is inert.

### Re-open without re-fetching

If the key is already installed and you only need the port back:

```powershell
Get-NetFirewallRule -DisplayName '*SSH*' | Enable-NetFirewallRule; Set-Service sshd -StartupType Manual; Start-Service sshd; Get-Service sshd
```

### Fully revoke, rather than just close

Closing leaves the fleet key authorised. To remove doc1's ability to log in even
if SSH is later re-enabled:

```powershell
Set-Content 'C:\ProgramData\ssh\administrators_authorized_keys' '' ; Remove-Item "$env:USERPROFILE\.ssh\authorized_keys" -Force -ErrorAction SilentlyContinue
```

### The trade-off in that one-liner

`iex (irm ...)` runs code from the internet as Administrator. That is a real
supply-chain exposure: anyone who could alter the GitHub mirror — or MITM the
fetch — would get admin on whatever box you paste it into. It is accepted here
because the mirror is our own read-only repo over HTTPS and the convenience at a
customer site is the entire point, but it is a deliberate trade, not a free lunch.

To harden, pin a commit instead of `master` so the content cannot change under you:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm 'https://raw.githubusercontent.com/abl030/nixosconfig/<commit-sha>/tools/windows/Setup-FleetSSH.ps1')
```

> Mirrored read-only to
> `github.com/abl030/nixosconfig/blob/master/docs/wiki/infrastructure/windows-fleet-ssh-access.md`
> so this can be copied from a phone while standing at the machine.

---

## What it is

A one-shot, self-contained PowerShell installer that authorises the fleet key
(`master-fleet-identity`, private half on doc1 only) on an arbitrary Windows box,
so doc1 can then manage it over OpenSSH like any other host.

It exists for the chicken-and-egg case: a Windows machine with **no usable account
password**, so there is no way to `scp`/SMB the key on first. Someone with console
access runs this once; after that doc1 has key-only access and the script is never
needed again.

## Running it

Elevated PowerShell on the target (it re-launches itself elevated if needed):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-FleetSSH.ps1
```

On a locked-down box where Group Policy pins the execution policy, the
`-ExecutionPolicy Bypass` flag is **silently overridden** by `MachinePolicy`.
An in-memory script block is not subject to execution policy at all:

```powershell
& ([scriptblock]::Create((Get-Content .\Setup-FleetSSH.ps1 -Raw)))
```

Useful switches: `-TargetUser <name>` (defaults to `Idealpos`), `-PublicKey <str>`,
`-HardenPasswordAuth`, `-AllowBlankPasswordAuth`, `-AnyRemote`.

## What it does

1. Ensures the OpenSSH Server capability is installed, Automatic, and running.
2. Adds a TCP 22 inbound rule scoped to LAN + tailnet, only if nothing already allows it.
3. Writes the key to **both** authorized-key locations, so it works whether or not
   the account is an administrator and whether or not the `Match Group administrators`
   block is present:
   - `C:\ProgramData\ssh\administrators_authorized_keys`
   - `<profile>\.ssh\authorized_keys`
4. Rebuilds the ACLs to `SYSTEM` + `Administrators` only (owner `Administrators`,
   inheritance off). sshd's StrictModes silently ignores a key file that anyone
   else can write.
5. Ensures `PubkeyAuthentication yes`, inserted **before** the first `Match` block.
6. Self-tests with a real loopback SSH login using a throwaway key, then removes it.

Idempotent. Existing authorised keys are preserved, never replaced. The original
`sshd_config` is kept at `sshd_config.fleet-backup`.

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

- If a target runs Windows older than 1809, `Add-WindowsCapability` has no OpenSSH
  package. Install the Win32-OpenSSH GitHub release manually first; the script
  detects an existing sshd and skips the install. `CULLENW-POS4` is Windows 10
  Enterprise 2016 LTSB (build 14393) and already had OpenSSH 10.0 installed this way.
- The script deliberately leaves `PasswordAuthentication` alone by default. On a
  box we own, consider `-HardenPasswordAuth` (it refuses unless the self-test passed,
  so it cannot lock you out).
