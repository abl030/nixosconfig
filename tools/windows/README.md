# Windows tools

## Setup-FleetSSH.ps1: give doc1 SSH access to a Windows PC

Open **PowerShell as Administrator** on the PC and paste this one line:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm 'https://raw.githubusercontent.com/abl030/nixosconfig/836c73e5fc5030d9f196f0e92113e3aa833e63c8/tools/windows/Setup-FleetSSH.ps1')
```

It is pinned to a tested commit, so the content cannot change under you.
SHA-256 of the script at that commit:
`0f6fe92d7454e9f003b1c5f90b8cc6c7c2e0cf3fd66019163d38391090870dab`

When it finishes, **photograph the framed panel** at the bottom. `RESULT` says
whether it worked; if it says to SSH as `fleet`, the PC uses a cloud (Entra ID)
account and a local admin `fleet` was created for SSH instead. On a domain-joined
PC the panel gives the login as `name@DOMAIN` (a bare name would hit the local
account). If it says `FAIL-SSHD-DELETE-PENDING` or `FAIL-REBOOT-NEEDED`, reboot
the PC and re-run. A failed OpenSSH install shows the installer's own error
lines in the panel, so the photo carries the cause.

With options (the plain one-liner cannot take any):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/abl030/nixosconfig/836c73e5fc5030d9f196f0e92113e3aa833e63c8/tools/windows/Setup-FleetSSH.ps1'))) -Persist
```

Options are listed at the top of [Setup-FleetSSH.ps1](Setup-FleetSSH.ps1).
Tests: `tests/` (offline unit tests run in `nix flake check`; the VM matrix
runs from the bastion). When the script changes, re-run both and update the pin
on this page.
