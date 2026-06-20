# Break-glass: a one-off privileged command on a LOCKED sibling

**Date:** 2026-06-20 · **Status:** documented procedure · **Issue:** [#232](https://github.com/abl030/nixosconfig/issues/232)

Every fleet host except the doc1 bastion is `homelab.fleetDeploy.role = "locked"`
— no passwordless sudo, abl030 keeps only a narrow read-only/deploy-hygiene
NOPASSWD allowlist (`modules/nixos/services/fleet-deploy.nix`), and the agent
reaches siblings only via doc1 + the polkit-gated `nixos-upgrade` trigger
(`fleet-deploy <host>`). See [ssh-bastion-model](ssh-bastion-model.md) and
[fleet-deploy-and-sibling-lockdown](fleet-deploy-and-sibling-lockdown.md).

That lockdown is deliberate, and it occasionally means **the agent cannot run a
privileged recovery command** it needs (e.g. `systemctl start <unit>`, removing a
root-owned runtime state file). The console (Proxmox / `wsl -u root` / prom
console) is the always-available break-glass, but when the operator wants the
agent to self-recover, use this **declarative, scoped, temporary** grant instead
of a standing privilege.

## Procedure

1. **Add a scoped, single-command NOPASSWD rule in `hosts/<H>/configuration.nix`**
   (NOT the shared `fleet-deploy.nix` allowlist — that would widen *every* locked
   host). Pin the exact command, mark it loudly as break-glass:

   ```nix
   # ─── BREAK-GLASS (TEMPORARY — REMOVE + REDEPLOY AFTER USE) ───
   security.sudo.extraRules = [
     {
       users = ["abl030"];
       commands = [
         {
           command = "/run/current-system/sw/bin/systemctl start <unit>.service";
           options = ["NOPASSWD"];
         }
       ];
     }
   ];
   ```

   Use the `/run/current-system/sw/bin/...` path form and include the full
   args — sudo matches the resolved command path + arguments literally (the
   same reason the standing allowlist names `.../systemctl restart podman-*`).
   NOPASSWD works even though the locked host's abl030 has **no password**:
   NOPASSWD bypasses the password prompt for that one command.

2. **Commit (signed), push to Forgejo, deploy:** `fleet-deploy <H>` from doc1.
   The grant change touches only sudoers — no app-unit derivations — so the
   switch won't restart services.

3. **Run the recovery command from doc1:**
   `ssh <H> "sudo /run/current-system/sw/bin/systemctl start <unit>.service"`
   (NOPASSWD needs no TTY, so this works over the non-interactive SSH hop.)

4. **Verify** the recovery worked.

5. **Delete the break-glass block, commit (signed), push, `fleet-deploy <H>`
   again.** The grant must not outlive the incident. Confirm it's gone:
   `ssh <H> "sudo -n /run/current-system/sw/bin/systemctl start <unit>.service"`
   should now fail with "a password is required" / "not allowed".

## Worked example — cratedigger gate hold (2026-06-20)

The `NoNewPrivileges` sweep (#232) added NNP to
`cratedigger-musicbrainz-maintenance-hold`, **changing its derivation**. That
unit is `requiredBy`/`before` the MusicBrainz maintenance units, so the doc2
switch restarted it → triggered the cratedigger↔musicbrainz gate cascade:
`musicbrainz.service` stopped (its `ExecStop` writes a `musicbrainz-maintenance`
hold under `/run/cratedigger-metadata-gate/`), its containers were torn down, and
cratedigger's app units (`cratedigger`, `-web`, `-importer`,
`-import-preview-worker`) stayed down because their `ExecCondition` gate-check
fails while a hold exists.

- MB containers were recovered with the *standing* allowlist (`sudo systemctl
  restart podman-musicbrainz-*` — already permitted on doc2).
- The **gate hold** only clears via `musicbrainz.service`'s `ExecStartPost`
  (`cratedigger-release-musicbrainz-maintenance-and-resume`), and a plain
  re-deploy won't restart an already-succeeded `RemainAfterExit` oneshot — so
  this break-glass granted `sudo systemctl start musicbrainz.service`, which
  released the hold and resumed cratedigger. Grant removed immediately after.

### Lesson / fragility to remember

**Editing any gate-coupled cratedigger unit** (the `*-maintenance-hold`, the
metadata-gate watchdog, or `musicbrainz.serviceConfig`) **changes its derivation
and tears MusicBrainz down on the next deploy**, leaving cratedigger gate-held.
Recover with `systemctl start musicbrainz.service` (releases the hold via its
ExecStartPost). The hold lives on `/run` (tmpfs), so a reboot also clears it —
doc2's nightly auto-update-with-reboot self-heals if you can wait. Avoid churning
those units' derivations unless necessary.
