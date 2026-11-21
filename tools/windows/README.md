# Windows tools

## Setup-FleetSSH.ps1: give doc1 SSH access to a Windows PC

Open **PowerShell as Administrator** on the PC and paste this one line:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm 'https://raw.githubusercontent.com/abl030/nixosconfig/a4d2d734a16d426017f3426146e8eadf8d85b9a5/tools/windows/Setup-FleetSSH.ps1')
```

It is pinned to a tested commit, so the content cannot change under you.
SHA-256 of the script at that commit:
`a99fdc1d82e9f8887e011fc84006a66302baf80d76566d15f786653250e6e449`

When it finishes, **photograph the framed panel** at the bottom. `RESULT` says
whether it worked; if it says to SSH as `fleet`, the PC uses a cloud (Entra ID)
account and a local admin `fleet` was created for SSH instead.

With options (the plain one-liner cannot take any):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/abl030/nixosconfig/a4d2d734a16d426017f3426146e8eadf8d85b9a5/tools/windows/Setup-FleetSSH.ps1'))) -Persist
```

Options are listed at the top of [Setup-FleetSSH.ps1](Setup-FleetSSH.ps1).
Tests: `tests/` (offline unit tests run in `nix flake check`; the VM matrix
runs from the bastion). When the script changes, re-run both and update the pin
on this page.
