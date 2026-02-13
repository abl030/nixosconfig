# Empirical Test: Compose Change Propagation on `igpu`

**Date:** 2026-02-13  
**Scope:** Verify whether compose file changes are applied to running rootless stack services after `git pull` + `nixos-rebuild switch`.

## Test Setup

- Added stack: `restart-probe` (`stacks/restart-probe/docker-compose.yml`)
- Service: `restart-probe-stack.service` (user scope)
- Baseline compose command:
  - `echo restart-probe ${PROBE_VERSION:-v1}`

## Change Under Test

- Modified compose command to:
  - `echo restart-probe-v2 ${PROBE_VERSION:-v1}`
- Flow executed on `igpu`:
  1. `git pull --rebase`
  2. `sudo nixos-rebuild switch --flake .#igpu`

## Observed Results

1. Git checkout on `igpu` was at the v2 commit.
2. Flake evaluation showed a new generated compose wrapper script path in `ExecStart`.
3. New system generation had updated unit content in `/etc/systemd/user/restart-probe-stack.service` (pointing at new wrapper path).
4. Running user manager still loaded a stale unit path from:
   - `~/.config/systemd/user/restart-probe-stack.service`
5. `systemctl --user daemon-reload` + `systemctl --user restart restart-probe-stack.service` still ran v1 command while stale home-level unit path remained active.
6. After removing user-level stale unit artifacts and reloading:
   - `FragmentPath` switched to `/etc/systemd/user/restart-probe-stack.service`
   - Container command switched to v2 (`restart-probe-v2 v1`)

## Raw Evidence (Key Paths)

- Stale home-level unit path observed:
  - `/home/abl030/.config/systemd/user/restart-probe-stack.service`
- New NixOS generation unit path observed:
  - `/etc/systemd/user/restart-probe-stack.service`
- New generated wrapper path observed in eval/system generation:
  - `/nix/store/nhkyrr0sbivia9sd9y70qx64jy2kdnpq-compose-with-systemd-label-restart-probe`
- Old generated wrapper path observed in active stale unit:
  - `/nix/store/i43cgjcm1snkx5r42chl9pjlqcg0bqpm-compose-with-systemd-label-restart-probe`

## Scope Boundary

This document records only observed behavior from the test run. It does not prescribe remediation.
