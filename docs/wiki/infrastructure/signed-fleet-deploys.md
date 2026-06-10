# Signed Fleet Deploys

**Date researched:** 2026-06-10
**Status:** Phase C enforcement is **live fleet-wide** (2026-06-10). Signing
(U2–U4), the verified `fleet-update` path (U5), the staleness watchdog (U6), and
the runbooks (U7) have all landed. `homelab.update.verify.enforce` +
`freshness.enable` are now `mkDefault true` in `base.nix`. The always-on servers
(doc1, doc2, igpu) were promoted in one step after the igpu canary's full
enforced nightly cycle was reproduced and verified end-to-end (real nixpkgs bump
deployed via the verified path, freshness advanced, watchdog green) — all three
deployed via `fleet-update`, enforcing, markers seeded, `FLEET-FRESHNESS OK`.
Intermittently-on workstations (epimetheus, framework, wsl) onboard on their next
nightly: `enforce` applies then, and the freshness watchdog reports non-paging
`PENDING` until their first verified deploy seeds the marker.

**Forgejo cutover is LIVE (Phase D, U8–U10, 2026-06-10).** Forgejo
(`git.ablz.au/abl030/nixosconfig`) is the write+fetch root: the rolling bot and
doc1's dev remote push to Forgejo (nixbot / doc1-writer tokens), and hosts fetch
`origins = {forgejo, github}` with `writeRoot = forgejo`. Validated end-to-end
(bot push → Forgejo → igpu enforced deploy from Forgejo). **GitHub is FROZEN at
the cutover commit** as a linear, ancestor-only fallback — no push mirror yet, so
it never advances and never diverges. The GitHub push-mirror, mirror poller, and
GitHub `master` ruleset remain deferred (blocked on the operator GitHub mirror
PAT); when added, GitHub becomes a hot fallback again.
**Related:** #235, #270, #232

This repo is moving from "whoever can update `master` can deploy the fleet" to
"every deployed commit must be SSH-signed by a key listed in the running host's
closure." The forge remains untrusted infrastructure: hosts trust the signed
history, not GitHub or Forgejo.

## Current State

Landed (U2–U7, all on `master`):

- `hosts.nix` has `signingKeys` for the human pushing machines:
  `epimetheus`, `framework`, `wsl`, and `proxmox-vm`.
- `hosts.nix` has `_signingPrincipals` for non-host service principals. The
  first one is `nix bot <acme@ablz.au>`.
- NixOS renders `/etc/fleet-update/allowed_signers` from `hosts.nix`.
- `nix flake check` has an always-run `allowedSignersCheck`.
- Home Manager writes git identity and enables SSH commit signing on hosts with
  a declared signing key.
- `rolling-flake-update.service` has a pinned remote URL, signs generated
  commits with `/var/lib/rolling-flake-update/bot_signing_key`, verifies the
  fetched base and every commit since its durable bot anchor, and commits
  `fleet/freshness.json` as a signed heartbeat with green/partial-failure
  status on every run.
- `fleet-update` is installed from the NixOS autoupdate verifier module. It
  keeps a root-owned full checkout at `/var/lib/fleet-update/repo`, verifies
  configured origin tips and the full deployment range against
  `/etc/fleet-update/allowed_signers`, then switches from an exact
  `git+file://...?rev=<sha>#<host>` flake reference.
- `fleet-update` authenticates the rolling bot heartbeat in
  `fleet/freshness.json` and writes local freshness markers under
  `/var/lib/fleet-update/`.

Landed and live:

- **Fleet-wide enforcement:** `enforce` + `freshness.enable` default true in
  `base.nix`. Always-on servers (doc1, doc2, igpu) enforcing as of 2026-06-10;
  workstations onboard on their next nightly.

Landed (Phase D, 2026-06-10):

- **U8** — `abl030/nixosconfig` on git.ablz.au (public, full history, anon read);
  restricted write accounts (`nixbot` + per-machine writers); `master` branch
  protection (force-push/delete blocked). [services/forgejo.md](../services/forgejo.md).
- **U9** — rolling bot pushes to Forgejo (nixbot token, header auth);
  doc1 dev remote repointed; `doc1-writer` token issued.
- **U10** — hosts fetch `{forgejo, github}`, `writeRoot = forgejo`.

Not yet landed:

- Phase D mirror leg — Forgejo→GitHub push-mirror, GitHub `master` ruleset, the
  mirror-health poller. **Blocked on the operator-created GitHub machine-user
  (`abl030-forgejo-mirror`) + fine-grained PAT** (GitHub does not mint PATs via
  API).
- Per-machine dev-push credential helper (declarative, in the HM git module) +
  epimetheus/framework/wsl writer tokens + remote repoints — doc1 done; the
  other pushers onboard when next at the machine.
- U11 docs sweep — the full grep of `github:abl030/nixosconfig` across wiki /
  readme / skills (CLAUDE.md + service-deploy already updated).

## Walk-through verification (2026-06-10)

The recovery runbooks were exercised live on igpu (the canary) after it was
brought to current tip. Verified: `fleet-update --probe-origins`, `--dry-run`,
the no-op path, the authenticated freshness watchdog (`FLEET-FRESHNESS OK`),
`--accept-new-root`, a real verified deploy through the local clone, and the
break-glass timer stop/start. The walk-through caught and fixed three bugs that
only bit the real (non-no-op) deploy and recovery paths — every earlier test was
a no-op because the host was already on tip:

- `--accept-new-root` set its force-deploy flag inside a `$(read_anchor)`
  command-substitution subshell, so the assignment was lost and the run
  classified as no-op. Bootstrap and history-rewrite recovery silently did not
  switch. Now gated on the parent-global `ACCEPT_NEW_ROOT`.
- `metadata_preflight` passed the `#<host>` flake fragment to `nix flake
  metadata`, which rejects it, so every real deploy failed at preflight. The
  fragment is now stripped for the metadata probe (nixos-rebuild keeps it).
- The break-glass runbooks used `systemctl disable --now`, which fails on
  NixOS's read-only `/etc/systemd/system`; corrected to `systemctl stop`/`start`
  with the rationale documented in **Break-Glass Host Deploy**.

igpu also moved into the passwordless-sudo server tier (doc1/doc2/wsl) so the
verified interactive `sudo fleet-update` deploy works over SSH, the same reason
its old passwordless-`nixos-rebuild` rule existed.

## Trust Model

`hosts.nix` is the trust root for commit-signing principals. The rendered
allowed-signers file uses OpenSSH SSH signature verification with namespace
`git`:

```text
abl030@proxmox-vm namespaces="git" ssh-ed25519 ...
"nix bot <acme@ablz.au>" namespaces="git" ssh-ed25519 ...
```

Human signing keys are local, signing-only keys at:

```sh
~/.ssh/id_ed25519_git_sign
```

They must not be added to `authorized_keys`, uploaded to Forgejo as account SSH
keys, synced between machines, or reused as login keys.

The bot signing key lives on doc1:

```sh
/var/lib/rolling-flake-update/bot_signing_key
```

It is under `/var/lib/rolling-flake-update`, which is `0700 abl030:users`; the
private key itself is `0600` and is read by `rolling-flake-update.service`. It is
distinct from the personal doc1 signing key and the old fleet SSH identity.

## Signing Key Setup

Generate a human signing key on the target machine:

```sh
ssh <host> 'umask 077
key="$HOME/.ssh/id_ed25519_git_sign"
mkdir -p "$HOME/.ssh"
test -e "$key" || ssh-keygen -t ed25519 -N "" -C "git-signing:$(hostname)" -f "$key"
chmod 600 "$key"
chmod 644 "$key.pub"
cat "$key.pub"'
```

Commit the public key into that host's `signingKeys` entry in `hosts.nix`. After
Home Manager deploys, verify a fresh commit:

```sh
git log --format='%G? %GS' -1
```

Expected status is `G` and the matching principal.

Home Manager owns legacy `~/.gitconfig` as a forced symlink to the generated
XDG Git config. This prevents an old per-user file from masking the declarative
SSH signing setup.

## Verified Host Deploy

On any host running the verifier module, the verified interactive deploy is:

```sh
sudo fleet-update
```

That command fetches the configured `homelab.update.verify.origins`, refuses
unsigned or divergent history, verifies every commit from the running
`system.configurationRevision` (or `/var/lib/fleet-update/last-verified-rev`
fallback) to the selected target, then runs `nixos-rebuild switch` from the
local verified clone pinned to the exact SHA. It also authenticates
`fleet/freshness.json`: the commit that last touched the file must verify
against `/etc/fleet-update/allowed_signers` and must be signed by
`nix bot <acme@ablz.au>`.

Useful manual modes:

```sh
sudo fleet-update --dry-run
sudo fleet-update --rev <40-char-master-sha>
sudo fleet-update --probe-origins
```

`--rev` must still be contained in protected `master` of the configured
`writeRoot`; arbitrary side-branch deploys are refused by default. A commit not
reachable from protected `master` (a side branch, a scratch fix) requires the
explicit `--allow-non-master` break-glass flag, which is for the Break-Glass
runbook only and is never used by the nightly path.

If a host has no usable anchor, bootstrap or re-anchor only after checking the
expected SHA out-of-band:

```sh
sudo fleet-update --accept-new-root <expected-40-char-sha>
```

Do not use this as trust-on-first-use. It is for explicit history rewrite or
bootstrap ceremonies.

## Freshness Markers

`fleet-update` maintains these local files:

```text
/var/lib/fleet-update/last-source-contact
/var/lib/fleet-update/last-verified-freshness
/var/lib/fleet-update/highest-seen-heartbeat
```

`last-source-contact` means at least one configured origin was reachable and
its branch tip verified with the running allowed-signers file. It is diagnostic
only; it is not enough to prove the fleet is not frozen.

`last-verified-freshness` records the authenticated heartbeat epoch, heartbeat
commit, target commit, and observation time. The watchdog checks the heartbeat
epoch age, not the marker file mtime, so replaying the same old signed
heartbeat cannot quiet the alert.

`highest-seen-heartbeat` is the monotonic anti-replay guard. A lower heartbeat
epoch never refreshes freshness, even if every commit is otherwise signed.

Freshness failures log lines beginning with:

```text
FLEET-FRESHNESS FAIL
```

Those are routed through `homelab.monitoring.errorPatterns` for
`nixos-upgrade.service` and `fleet-update-freshness.service`. The watchdog unit
is present on hosts with the verifier module, but its timer is intentionally
off until `homelab.update.verify.freshness.enable = true`; flip that alongside
the verified nightly enforcement gate, not before every host is using
`fleet-update`.

The accepted heartbeat age is host-classed automatically: laptops
(`homelab.update.checkAcPower = true`) get a 72h AC/offline grace, always-on
servers page after 30h (one missed nightly window). A laptop offline past 72h
pages by design — that is the intended signal, not a false positive.

## Enabling Enforcement (Trust-Root Ceremony)

Turning enforcement on is the moment a single unsigned commit anywhere in a
host's deployment range starts failing that host's nightly update loudly. It is
fail-closed by design (noisy, not dangerous), but do it deliberately: canary
host first, never fleet-wide in one commit.

Two independent flags gate enforcement, both default `false`:

- `homelab.update.verify.enforce` — `nixos-upgrade.service` runs the verified
  `fleet-update` path (and uses it as the `ExecCondition` reachability probe)
  instead of the raw GitHub flake switch.
- `homelab.update.verify.freshness.enable` — the local signed-heartbeat
  watchdog timer that pages on a frozen fleet.

Flip both together on a given host. Enforcement without the watchdog can be
frozen on a vulnerable rev silently; the watchdog without enforcement pages a
host that is not yet using the verified path.

### Step 1 — trust-root ceremony (once, before the first enforcing host)

1. Freeze writes to `master`. Stop the rolling bot so it cannot push
   mid-ceremony (`stop`, not `disable` — see the read-only `/etc` note in
   **Break-Glass Host Deploy**):

   ```sh
   sudo systemctl stop rolling-flake-update.timer   # on doc1
   ```

2. Pick the exact rev that becomes the enforcement root and record it
   out-of-band (it is the expected anchor for every host's first enforcing run):

   ```sh
   git fetch origin
   root_sha="$(git rev-parse origin/master)"; echo "$root_sha"
   ```

3. Render the allowed-signers file that this rev will bake, then independently
   confirm every principal in it. Collect each public key's fingerprint
   out-of-band from the machine that generated it — read it on that machine, do
   not trust the value in the repo — and confirm the root rev itself verifies:

   ```sh
   tmp_allowed="$(mktemp)"
   nix eval --impure --raw \
     ".#nixosConfigurations.igpu.config.environment.etc.\"fleet-update/allowed_signers\".text" \
     > "$tmp_allowed"
   cat "$tmp_allowed"   # one principal per line — verify each fingerprint by hand
   git -c gpg.ssh.allowedSignersFile="$tmp_allowed" verify-commit "$root_sha"
   rm -f "$tmp_allowed"
   ```

   An unexpected or unrecognised principal, or a `verify-commit` failure, is
   tamper. Stop and investigate — do not enable enforcement from this rev.

### Step 2 — canary host (igpu)

1. Set both flags on the canary only:

   ```nix
   # hosts/igpu/configuration.nix
   homelab.update.verify.enforce = true;
   homelab.update.verify.freshness.enable = true;
   ```

2. Commit signed, push, and deploy the canary the standard way (this is a config
   change, so it still goes out via the GitHub-flake switch; after it lands the
   host carries `fleet-update` and enforces from the next deploy on):

   ```sh
   ssh igpu "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#igpu --refresh"
   ```

   From here, canary deploys use the verified path: `ssh igpu "sudo fleet-update"`.

3. Re-arm the rolling bot and let at least one full nightly cycle run with the
   canary enforcing:

   ```sh
   sudo systemctl start rolling-flake-update.timer    # on doc1
   ```

4. Confirm the enforcing nightly was green and freshness stayed quiet:

   ```sh
   ssh igpu 'systemctl status nixos-upgrade.service --no-pager | head -5
   journalctl -u nixos-upgrade.service -n 80 --no-pager
   cat /var/lib/fleet-update/last-verified-freshness'
   ```

### Step 3 — fleet-wide

Only after the canary soaks one clean enforcing cycle, move both flags to the
fleet default in `modules/nixos/profiles/base.nix` and delete the igpu override.
doc2's update window must stay latest in the fleet so its own fix is always
reachable by the rest. Watch the first fleet-wide enforcing night: an unsigned
commit in any host's deployment range fails that host loudly and is recovered
via **Break-Glass Host Deploy**.

## Bot Signing

Generate the bot key on doc1 only:

```sh
ssh doc1 'sudo install -d -m 0700 -o abl030 -g users /var/lib/rolling-flake-update
sudo -u abl030 sh -c '"'"'umask 077
key=/var/lib/rolling-flake-update/bot_signing_key
test -e "$key" || ssh-keygen -t ed25519 -N "" -C git-signing:nix-bot -f "$key"
chmod 600 "$key"
chmod 644 "$key.pub"
cat "$key.pub"'"'"''
```

The public key belongs in `_signingPrincipals`:

```nix
{
  principal = "nix bot <acme@ablz.au>";
  key = "ssh-ed25519 ... git-signing:nix-bot";
}
```

Before enabling `requireSignedBase`, the current `origin/master` must verify
against `/etc/fleet-update/allowed_signers`. The deployment commit that turns
on the bot preflight must itself be signed by an allowed human key, otherwise
the first nightly run correctly refuses to build on that base.

The bot also needs a durable anti-replay anchor at
`/var/lib/rolling-flake-update/last-verified-base`. The anchor must be the exact
signed `master` commit that doc1 is expected to build on. Seed it immediately
after the fast-forward merge and before enabling/running the bot:

```sh
sha="$(git rev-parse master)"
tmp_allowed="$(mktemp)"
nix eval --impure --raw .#nixosConfigurations.proxmox-vm.config.environment.etc.\"fleet-update/allowed_signers\".text > "$tmp_allowed"
git -c gpg.ssh.allowedSignersFile="$tmp_allowed" verify-commit "$sha"
ssh doc1 "sudo install -d -m 0700 -o abl030 -g users /var/lib/rolling-flake-update && printf '%s\n' '$sha' | sudo -u abl030 tee /var/lib/rolling-flake-update/last-verified-base >/dev/null"
rm -f "$tmp_allowed"
```

If this file is absent, malformed, or not contained in the fetched history, the
bot refuses to commit. This is deliberate: a signed replay or a signed merge
that introduces unsigned side history must not be laundered by a fresh bot
heartbeat.

Do not merge the enabling commit with a GitHub web merge, squash, or rebase
button unless the resulting `master` tip is explicitly verified with the fleet
allowed signers. Those flows can create a new GitHub-signed or unsigned tip
that is not trusted by hosts. For the initial rollout, fast-forward `master` to
the already-signed commit from a signed local checkout, then verify:

```sh
git checkout master
git pull --ff-only origin master
git merge --ff-only feat/signed-fleet-deploys
git push origin master
tmp_allowed="$(mktemp)"
nix eval --impure --raw .#nixosConfigurations.proxmox-vm.config.environment.etc.\"fleet-update/allowed_signers\".text > "$tmp_allowed"
git -c gpg.ssh.allowedSignersFile="$tmp_allowed" verify-commit master
rm -f "$tmp_allowed"
```

Dry-run without pushing:

```sh
NO_COMMIT=1 ONLY_GROUP=llm ./scripts/rolling_flake_update.sh
```

If the group has no input changes, the heartbeat still gives a signed local
commit to inspect. Its JSON includes `status`, `failed_groups`, and
`summary_lines`; freshness consumers must treat `status = "partial_failure"` as
a failed run, not as a green update.

Failed update groups copy full logs and local git state under:

```text
/var/lib/rolling-flake-update/failures/<timestamp>-<group>/
```

Fatal non-group failures preserve the temporary clone and scrub the remote URL
back to a tokenless form before printing the recovery path. Treat preserved
workdirs as sensitive until inspected.

## Break-Glass Host Deploy

Use this only when the signed update path is blocked and a host must be fixed
manually. Reach siblings (igpu, doc2, ...) through doc1, the SSH bastion — they
hold no fleet key. Run these steps in a shell on the affected host itself.

1. Stop the timer first. Use `stop`, not `disable` — NixOS renders
   `/etc/systemd/system` as a read-only symlink tree, so `disable`/`enable`
   cannot remove/add the `timers.target.wants` symlink and fail with
   `Read-only file system`. `stop`/`start` are the runtime controls; the unit
   stays Nix-enabled and re-arms on the next reboot or `nixos-rebuild`, which is
   why step 6 re-arms it explicitly:

   ```sh
   sudo systemctl stop nixos-upgrade.timer
   ```

2. Fix from a local checkout on the affected host. Follow the repo rebuild
   safety rules: check `hostname`, `date`, `git fetch`, and `git status -sb`
   before any `nixos-rebuild switch`.
3. Deploy the local fix.
4. Push the signed fix to the normal write root.
5. Return the host to the verified path. If the signed fix is now the `master`
   tip, just re-run the verified update so the host re-anchors onto it:

   ```sh
   sudo fleet-update
   ```

   If history was rewritten or the host has no usable anchor, re-anchor to the
   explicit, out-of-band-confirmed SHA:

   ```sh
   sudo fleet-update --accept-new-root <expected-sha>
   ```

   To deploy a signed commit that is not yet on `master` (an emergency scratch
   fix), add the break-glass flag — it stops timers and pages the bypass:

   ```sh
   sudo fleet-update --rev <scratch-sha> --allow-non-master
   ```

   Redeploy from `master` as soon as the fix is merged and signed.
6. Re-arm the timer:

   ```sh
   sudo systemctl start nixos-upgrade.timer
   ```

Stopping the timer is load-bearing. Otherwise the next nightly update can
revert the local dirty deployment.

## Rolling Bot Failure

This is for failures in `rolling-flake-update.service` on doc1, not a host
`nixos-upgrade` failure.

1. Stop the bot timer first (`stop`, not `disable` — see the read-only `/etc`
   note in **Break-Glass Host Deploy**):

   ```sh
   sudo systemctl stop rolling-flake-update.timer
   ```

2. Inspect the run:

   ```sh
   journalctl -u rolling-flake-update.service -n 300 --no-pager
   ls -la /var/lib/rolling-flake-update/failures/ 2>/dev/null || true
   cat /var/lib/rolling-flake-update/last-verified-base
   ```

3. For a missing bot key, recreate only on doc1 using the command in
   **Bot Signing**, then commit the public key if it changed.
4. For an anchor failure, do not overwrite the anchor until the expected
   `master` SHA has been verified against the fleet allowed signers. A rollback
   or signed side branch is a tamper signal.
5. After the fix, run the service once while watching the journal:

   ```sh
   sudo systemctl start rolling-flake-update.service
   journalctl -u rolling-flake-update.service -n 300 --no-pager
   ```

   For a manual dry-run instead of the systemd unit, copy the `Environment=`
   values from `systemctl cat rolling-flake-update.service`, add
   `NO_COMMIT=1 ONLY_GROUP=none`, and invoke the ExecStart wrapper shown there
   from `WorkingDirectory=/home/abl030/nixosconfig`.
6. Re-arm the timer:

   ```sh
   sudo systemctl start rolling-flake-update.timer
   ```

## Key Add And Remove

Add:

1. Generate the private key on the machine that will use it.
2. Commit the public key to `hosts.nix`, signed by an already trusted key once
   enforcement is live (a key-introduction commit must itself verify).
3. Wait until every NixOS host has deployed a closure that carries the new
   allowed-signers file. A lagging host is acceptable only if it has an explicit
   manual re-anchor plan (deploy it onto a closure carrying the key before it is
   ever asked to deploy a commit signed by that key). Confirm propagation:

   ```sh
   for h in proxmox-vm igpu doc2 epimetheus framework; do
     printf '%s: ' "$h"
     ssh "$h" "grep -Fq '<new-pubkey-or-principal>' /etc/fleet-update/allowed_signers \
       && echo present || echo MISSING"
   done
   ```

4. Only then use the new key for fleet-valid commits.

Remove:

1. Stop using the old key.
2. Confirm every lagging host is either updated or has an explicit manual
   re-anchor plan.
3. Remove the public key from `hosts.nix` in a signed commit.
4. Verify `/etc/fleet-update/allowed_signers` no longer contains the key on
   every NixOS host.

This is observation-gated, not time-gated. Do not remove a key just because a
day has passed.

## Active Key Compromise

If a signing key is suspected compromised:

1. Freeze writes to the repo (stop the rolling bot timer on doc1).
2. Revoke that identity's push credentials on Forgejo and GitHub.
3. Land an exact key-removal commit signed by a different trusted key. Record
   its SHA out-of-band.
4. Deploy that commit fleet-wide by its exact rev, reaching siblings through
   doc1:

   ```sh
   for h in proxmox-vm igpu doc2 epimetheus framework; do
     ssh "$h" "sudo fleet-update --rev <removal-sha>"
   done
   ```

5. Verify the stolen public key is absent from every host's
   `/etc/fleet-update/allowed_signers` (reuse the propagation check from
   **Key Add And Remove**, expecting `MISSING`).
6. Unfreeze writes.

If the whole trusted key set is suspect, use the break-glass local deploy path
instead of relying on the old signers list.

## History Rewrite Or New Root

Do not silently trust a new signed root. Bootstrap and history-rewrite recovery
must pin an explicit, independently confirmed expected SHA — never
trust-on-first-verify:

```sh
sudo fleet-update --accept-new-root <expected-sha>
```

After confirming the rewritten history once out-of-band, re-anchor every host to
the same SHA, reaching siblings through doc1:

```sh
for h in proxmox-vm igpu doc2 epimetheus framework; do
  ssh "$h" "sudo fleet-update --accept-new-root <expected-sha>"
done
```

A signed old replay or an unrelated signed side branch must not become the new
anchor by accident — which is exactly why the SHA is supplied explicitly rather
than inferred from whatever the origin currently advertises.

## Accepted Residual Risk

Signed deploys do not solve every supply-chain problem:

- doc1 as `abl030` remains able to author fleet-valid bot commits by design;
- a compromised developer machine can sign with its local key until that key is
  revoked and the removal propagates;
- flake inputs and private GitHub inputs remain external supply chain;
- Forgejo/GitHub branch protections are defense-in-depth, not the host trust
  anchor.

The control being added here is narrower: hosts must not deploy unsigned,
untrusted, or replayed repo history.
