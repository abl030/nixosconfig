# GitHub PAT rotation & private flake inputs

**Status**: working (Phase 1 shipped 2026-04-17, Phase 2 pending).
**Issue**: [#210](https://github.com/abl030/nixosconfig/issues/210) — the incident that motivated this.

## Problem we're solving

`nixosconfig` is public, but one flake input is private: `abl030/vinsight-mcp`.
Because nix's `access-tokens` is a **global credential**, a stale PAT in
`/run/secrets/nix-access-tokens` makes GitHub return `401` on *every*
`github.com` request — including fetches of public repos. When the PAT
rotates, the whole fleet's auto-upgrades quietly die with 401 errors until
someone manually intervenes (this is what killed igpu's upgrades for 5
weeks in March/April 2026).

The fix is two-part:

1. **Phase 1** — re-architect token handling so a stale PAT degrades
   gracefully. Add infrastructure for SSH-based private input fetches.
2. **Phase 2** — switch `vinsight-mcp` from `github:abl030/vinsight-mcp`
   (HTTPS+PAT) to `git+ssh://git@github.com/abl030/vinsight-mcp` (SSH
   deploy key). SSH keys don't expire; the fleet-wide PAT can rotate
   without affecting private-input fetches.

## Phase 1 pieces (merged 2026-04-17)

### `modules/nixos/lib/refresh-access-tokens.nix`

Shared derivation that:

- Reads the PAT from `/run/secrets/nix-netrc`.
- Validates it against `https://api.github.com/user` (5s timeout).
- Writes `/run/secrets/nix-access-tokens` **only if the PAT is valid or
  the validation was inconclusive** (network/DNS blip).
- Writes an empty file on a definitive `401`/`403` so subsequent fetches
  go anonymous instead of poisoned.

Called from two places:

- `modules/nixos/profiles/base.nix` — activation script
  (`system.activationScripts.nix-access-tokens`). Runs on every switch
  and on every boot, keeping the file in sync with netrc state.
- `modules/nixos/autoupdate/update.nix` — `ExecStartPre` on
  `nixos-upgrade.service`. **This is the critical one** — it runs
  immediately before the flake fetch, so a stale PAT cannot poison the
  nightly upgrade. Without it, the activation-script fix only helps the
  *next* upgrade (post-switch), which never runs because the current one
  failed.

### `modules/nixos/services/ssh/default.nix`

Three additions, all gated on the existing `cfg.deployIdentity`:

- **Root identity mirror** — an activation script copies the
  sops-decrypted fleet key from `${homeDirectory}/.ssh/id_ed25519` to
  `/root/.ssh/id_ed25519` (mode `0400`, owned by root). Root needs its
  own copy because `nixos-upgrade.service` runs as root and cannot read
  `~abl030/.ssh/id_ed25519` via `IdentityFile` (user-owned, 0600).
- **System-wide ssh_config** for `github.com`, scoped to
  `Match User root`. Pins algorithms to ssh-ed25519, disables agent
  fallback, points `IdentityFile` at `/root/.ssh/id_ed25519`. The
  `Match User root` scope is important — without it, regular users'
  `git push` would hit the same block and fail on permission-denied
  trying to read root's key.
- **known_hosts pin** for `github.com` with GitHub's documented ed25519
  fingerprint, so root's SSH to github.com never TOFUs. (Update if
  GitHub rotates — very rare; last rotation was 2023-03-24 for RSA.)

## Phase 2 (pending, staged as PR)

`flake.nix` — change:

```nix
vinsight-mcp = {
  url = "github:abl030/vinsight-mcp";
  ...
};
```

to:

```nix
vinsight-mcp = {
  url = "git+ssh://git@github.com/abl030/vinsight-mcp";
  ...
};
```

Plus `nix flake lock --update-input vinsight-mcp` to refresh the lock.

The Phase 1 SSH infrastructure must be live fleet-wide *before* Phase 2
merges — otherwise hosts whose nightly upgrade fires before they've
received Phase 1 will fail the first attempt (root has no key yet). After
one successful upgrade cycle under Phase 1 (~24h), every host has
`/root/.ssh/id_ed25519`, and Phase 2 is safe to merge.

### Deploy key on vinsight-mcp

Added via `gh api repos/abl030/vinsight-mcp/keys`. Uses the fleet
identity public key (see `hosts.nix:masterKeys`), read-only, title
`fleet-identity (ssh_key_abl030) - read only`.

## Recovery flow after PAT rotation (post Phase 2)

1. User rotates PAT on GitHub, re-encrypts `secrets/nix-netrc`, commits,
   pushes.
2. Nightly `nixos-upgrade.service` fires on a host.
3. `ExecStartPre` runs `refresh-nix-access-tokens`:
   - Validates the (still old) PAT → 401 → writes empty file.
4. `nixos-rebuild switch --flake github:abl030/nixosconfig#<host>`:
   - Public repos fetch anonymously (rate-limited to 60/hr but fine for
     a single upgrade).
   - `vinsight-mcp` fetches via SSH with root's deploy key → works.
5. Activation completes → new netrc with new PAT is now decrypted →
   activation script revalidates, writes fresh access-tokens.
6. Next upgrade: fully authenticated, no rate-limit concerns.

## New-host bootstrap

`vms/post-provision.sh` uses `nixos-rebuild switch --target-host`, which
builds the closure on the **provisioning host** and ships it to the new
VM. The provisioning host has the fleet key in its user account, so
git+ssh fetches work during the build. The VM receives a fully-activated
closure on first boot; our activation script then mirrors the key into
`/root/.ssh/id_ed25519` for future self-rebuilds.

**Caveat**: if someone ever provisions a new host by SSHing in and
running `nixos-rebuild switch --flake github:...#<vm>` *from the VM* as
the first step (no `--target-host`), the fetch will fail because
`/root/.ssh/id_ed25519` doesn't exist yet. Workaround: pre-seed with
`sudo install -d -m 0700 /root/.ssh && sudo install -m 0400 -o root -g root ~/.ssh/id_ed25519 /root/.ssh/id_ed25519`
before the first rebuild. Post-provision.sh does not hit this path.

## Why not make vinsight-mcp public?

It's the one flake input that legitimately needs to stay private
(upstream winery API client with credentials in the client code).
Everything else in `flake.nix` is already public.

## Why not a long-lived PAT?

Kicks the can. A 1-year PAT still expires; the same 5-week outage
happens again, just once a year. The git+ssh approach eliminates expiry
entirely and keeps the PAT purely as a rate-limit nicety.
