# Windows tools

## Setup-FleetSSH.ps1: give doc1 SSH access to a Windows PC

Open **PowerShell as Administrator** on the PC and paste this one line:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm 'https://raw.githubusercontent.com/abl030/nixosconfig/6a70e7fff909684c9b4a0731c8901247b5794671/tools/windows/Setup-FleetSSH.ps1')
```

It is pinned to a tested commit, so the content cannot change under you.
SHA-256 of the script at that commit:
`28a77d15e17f214448708477ed61323787da05f73c4bc38b7fa50660964f211b`

When it finishes, **photograph the framed panel** at the bottom. `RESULT` says
whether it worked; if it says to SSH as `fleet`, the PC uses a cloud (Entra ID)
account and a local admin `fleet` was created for SSH instead.

With options (the plain one-liner cannot take any):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/abl030/nixosconfig/6a70e7fff909684c9b4a0731c8901247b5794671/tools/windows/Setup-FleetSSH.ps1'))) -Persist
```

Options are listed at the top of [Setup-FleetSSH.ps1](Setup-FleetSSH.ps1).
Tests: `tests/` (offline unit tests run in `nix flake check`; the VM matrix
runs from the bastion). When the script changes, re-run both and update the pin
on this page.
