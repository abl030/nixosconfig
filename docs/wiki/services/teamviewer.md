# TeamViewer

- Date researched: 2026-04-22
- Status: working via upstream NixOS module
- Hosts: `framework`, `epimetheus`

## What works

- `services.teamviewer.enable = true;` is available in nixpkgs and installs both the `teamviewer` package and the `teamviewerd` systemd service.
- This repo already allows unfree packages in the base profile, so TeamViewer does not need any extra `allowUnfree` override on desktop hosts like `framework` or `epimetheus`.

## Verification in this session

- Confirmed nixpkgs exposes `pkgs.teamviewer` at version `15.74.3`.
- Confirmed nixpkgs ships a native `services.teamviewer` module that adds the package, D-Bus integration, and `teamviewerd`.

## Revisit

- If TeamViewer breaks after a nixpkgs bump, inspect the upstream package at `pkgs/by-name/te/teamviewer/package.nix` and module at `nixos/modules/services/monitoring/teamviewer.nix`.
