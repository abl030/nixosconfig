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

## 2026-10-26: 15.82.6 segfaults at startup

- nixpkgs bumped TeamViewer 15.81.5 -> 15.82.6. On epimetheus `teamviewerd`
  SIGSEGVs inside `ld-linux` (`dl_main`) before any TeamViewer code runs, hits
  the start limit, and makes `switch-to-configuration` exit 4, so nightly
  nixos-upgrade reports failure. No upstream report found at the time.
- It builds fine, so the rolling updater's build-based package hold would
  release it the next night. Instead `nix/overlay.nix` pins it by version: while
  nixpkgs ships exactly 15.82.6 it takes 15.81.5 from `nixpkgs-held`; any other
  version releases the pin automatically.
- Revisit: once nixpkgs moves past 15.82.6, confirm `teamviewerd` starts on epi
  or framework, then delete the overlay block.
