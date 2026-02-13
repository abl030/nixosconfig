# igpu NixOS Upgrade Unit Escape Test Plan

## Goal
Fix `nixos-upgrade.service` failure on `igpu` caused by malformed generated systemd unit content, while minimizing risk and validating with reproducible steps.

## Scope
- Host: `igpu` (via `ssh igp`)
- Failure window: `2026-02-13 01:55:48 AWST`
- Target area: generated service content from `stacks/lib/podman-compose.nix`
- Out of scope: unrelated stack behavior and non-igpu hosts during initial validation

## Constraints
- Do not directly modify production service behavior until escaping is proven in isolation.
- Prefer `nixos-rebuild test` for iteration.
- Keep rollback path ready at all times.

## Plan

1. Baseline capture (remote)
- Collect definitive failure evidence:
  - `journalctl -u nixos-upgrade.service -b --no-pager | tail -n 300`
  - `journalctl -b --no-pager | rg -n "igpu-management-stack|bad unit file|unknown escape|age_seconds|NOPERMISSION"`
- Save signature lines for before/after comparison.

2. Add isolated test harness (repo)
- Add temporary igpu-only module defining:
  - `escape-lab-broken.service` replicating current problematic escaping style.
  - `escape-lab-fixed.service` using candidate corrected escaping.
- Ensure these units are independent from `igpu-management-stack.service`.

3. Parse validation before activation
- Build target system:
  - `nix build .#nixosConfigurations.igpu.config.system.build.toplevel`
- Validate generated unit files with:
  - `systemd-analyze verify <unit-file>`
- Iterate until fixed variant has no parse/escape warnings.

4. Remote test deployment (non-persistent)
- Deploy with:
  - `nixos-rebuild test --flake .#igpu --target-host igpu`
- Start both test units and compare behavior:
  - `sudo systemctl start escape-lab-broken.service`
  - `sudo systemctl start escape-lab-fixed.service`
  - `journalctl -u escape-lab-broken.service -u escape-lab-fixed.service -b --no-pager`

5. Apply proven pattern to real module
- Update escaping in `stacks/lib/podman-compose.nix` (`detectStaleHealth`/related lines).
- Rebuild and redeploy with `test`.
- Validate:
  - `sudo systemctl daemon-reload`
  - `sudo systemctl start igpu-management-stack.service`
  - `journalctl -u igpu-management-stack.service -b --no-pager | tail -n 300`

6. Upgrade-path validation
- Trigger previously failing path:
  - `sudo systemctl start nixos-upgrade.service`
- Confirm:
  - no `bad unit file setting`
  - no `unknown escape sequences`
  - no `status=4/NOPERMISSION` for this incident

7. Promote and cleanup
- If successful:
  - `nixos-rebuild switch --flake .#igpu --target-host igpu`
- Remove temporary `escape-lab-*` harness.
- Re-run minimal validation after removal.

8. Rollback
- If regression occurs:
  - `sudo nixos-rebuild switch --rollback`
  - reboot into previous generation if required

## Success Criteria
- `igpu-management-stack.service` starts cleanly.
- `nixos-upgrade.service` completes without unit-file parse failure.
- No systemd escape/parse warnings tied to injected shell.
- Temporary harness removed after validation.
