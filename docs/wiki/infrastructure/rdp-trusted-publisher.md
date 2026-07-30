# Signing .rdp shortcuts to stop the "Do you trust this remote connection?" prompt

**Status:** applied 2026-07-30 on `CULLENW-POS4`; **confirmed by the operator at the
console** — the trust prompt no longer appears
**Script:** `tools/windows/Set-RdpSignedShortcut.ps1`
**Context:** Cullen site POS terminals connecting to the terminal server `CW-TS01`

## The symptom

Staff double-click the RDP shortcut, log in, and get a modal dialog:

```
Do you trust this remote connection?
[x] Printers   [ ] Clipboard   [ ] Smart cards
[ ] Don't ask me again for connections to this computer
```

During busy service this sits between the operator and the till. It appears
*after* authentication, so nothing set beforehand carries through.

## Why "Don't ask me again" had not fixed it

Ticking that box writes a **bitmask** to:

```
HKCU\Software\Microsoft\Terminal Server Client\LocalDevices\<server>
```

recording *which* redirections were approved. On `CULLENW-POS4` this was already
set to `76` — someone had ticked it, possibly years ago. But `76` does not
include the clipboard bit, and `Server.rdp` requests
`redirectclipboard:i:1`. Any redirection the file asks for that is *not* in the
mask re-triggers the prompt, every single connection.

So the box looked "already answered" while still prompting forever. Check the
actual value before assuming the user never ticked it.

## The fix

Sign the `.rdp` with a code-signing certificate and add that certificate to the
client's trusted-`.rdp`-publishers list. The RDP client then trusts every setting
inside the signature scope and stops asking. This is Microsoft's supported
mechanism, it survives profile resets, and the signed file can simply be copied
to other terminals.

```powershell
# On the client, elevated:
.\Set-RdpSignedShortcut.ps1 -RdpPath 'C:\Users\Idealpos\Desktop\Server.rdp' `
    -Subject 'CN=Cullen RDP Publisher' -ExportDir 'C:\rdp-publisher'

# On any OTHER terminal — public cert only, no private key, no signing:
.\Set-RdpSignedShortcut.ps1 -TrustOnly -CerPath '\\share\RdpPublisher.cer'
```

The signed `Server.rdp` is portable: copy it to the other terminals, run
`-TrustOnly` there, done.

Undo: `.\Set-RdpSignedShortcut.ps1 -Undo -RdpPath '<path>'` restores the
`.unsigned-backup` and clears the policy values.

## Trusted Root is required, and why that is acceptable here

**A self-signed publisher certificate must go into Trusted Root as well as
TrustedPublisher.** This was learned the hard way: the first attempt deliberately
skipped Root on least-privilege grounds, and the client still showed
*"Publisher: Unknown publisher"* with the prompt intact. The chain check told the
story:

```
UntrustedRoot - A certificate chain processed, but terminated in a root
                certificate which is not trusted by the trust provider.
```

TrustedPublisher plus the `TrustedCertThumbprints` policy is **not** sufficient on
its own -- the certificate chain still has to validate. The script now installs to
both stores and then *verifies the chain builds*, failing loudly if it does not,
so this cannot silently regress.

The exposure is narrower than "trusting a CA", and the specifics matter:

- **EKU is Code Signing only.** It cannot vouch for a TLS server certificate, so it
  cannot be used to intercept HTTPS on that terminal.
- **No CA basic constraint** -- it is an end-entity certificate, so it cannot issue
  or vouch for any *other* certificate. It only ever validates signatures made by
  its own key.

So the real risk is: whoever holds that private key can sign code and `.rdp` files
that this terminal treats as a trusted publisher. The key stays in the signing
machine's `LocalMachine\My`; other terminals receive the public `.cer` only.

Where a real CA exists, issue a chaining code-signing certificate instead and pass
`-NoRootTrust`. In a workgroup with no CA, self-signed plus Root is the available
answer.

## Also not done

- **The terminal server is not touched.** This is entirely client-side.
- **`full address` is left alone**, so the shortcut still connects where it did.
- The private key is never exported to the other terminals.

## Gotchas

- `rdpsign.exe /sha256 <hash>` — the `/sha256` selects the **signature** hash
  algorithm; the argument after it is the certificate's ordinary **SHA1**
  thumbprint (`$cert.Thumbprint`). The flag name invites the opposite assumption.
  Verified against a live `rdpsign.exe`.
- The client-side policy value is likewise a **SHA1** thumbprint list
  (`TrustedCertThumbprints`, comma-separated `REG_SZ`). Append, never overwrite,
  or you silently revoke other publishers.
- `AllowSignedFiles = 1` is set alongside it; without it a signed file from an
  otherwise-unknown publisher can still prompt.
- **Editing a signed `.rdp` breaks the signature** and the prompt returns. Re-run
  the script after any change to the shortcut.
- `New-Object X509Certificate2($bytes)` **unrolls the byte array into one argument
  per byte** ("no overload ... argument count: 782"). Use
  `[X509Certificate2]::new($bytes)`. Same PowerShell array-unrolling family as the
  bug documented in [windows-fleet-ssh-access.md](windows-fleet-ssh-access.md).

## What this does NOT fix

A separate warning — *"The identity of the remote computer cannot be verified"* —
comes from the **server's** certificate, not the `.rdp` file, and signing does
nothing for it. As of 2026-07-30 `CW-TS01` (`192.168.100.202`) presents a
self-signed certificate:

```
Subject/Issuer : CN=CW-TS01.cullenwines.com.au   (self-signed)
Valid          : 2026-05-20 -> 2026-11-19
```

Two problems if that warning ever needs fixing: the `.rdp` connects to the short
name `CW-TS01` while the certificate says `CW-TS01.cullenwines.com.au` (name
mismatch), and it is the auto-generated cert Windows rotates roughly every six
months, so pinning its thumbprint would break again in November. The durable fix
is a long-lived cert with proper SANs bound to CW-TS01's RDP listener
(`Win32_TSGeneralSetting.SSLCertificateSHA1Hash`) plus a one-time trust import on
each client. That requires access to CW-TS01 and has not been done.

The site is **WORKGROUP, not domain-joined** — there is no AD, no enterprise CA and
no GPO to distribute trust, so every client change is per-machine.

## State on CULLENW-POS4

| | |
|---|---|
| Publisher | `CN=Cullen RDP Publisher`, SHA1 `AC266169F886DF3D7D28C66A0CC6EB19A2EAF7E5`, expires 2036-07-30 |
| Public cert | `C:\rdp-publisher\RdpPublisher.cer` |
| Backup | `C:\Users\Idealpos\Desktop\Server.rdp.unsigned-backup` |
| `LocalDevices\CW-TS01` | `76` -> `255` (belt; restore with `76` if you want to isolate the signing path) |

Both the signature path and the `LocalDevices` belt are in place, so which one is
doing the work was not isolated. Set the value back to `76` and retest if you ever
need to prove the signing path alone.

## Rolling this out to the other terminals

The signed `Server.rdp` is portable — the signature covers the file's settings, not
the machine. On each additional terminal: copy the signed `.rdp` over, copy
`RdpPublisher.cer` from `C:\rdp-publisher\`, then run

```powershell
.\Set-RdpSignedShortcut.ps1 -TrustOnly -CerPath '<path>\RdpPublisher.cer'
```

No private key leaves the signing box, and nothing needs re-signing.
