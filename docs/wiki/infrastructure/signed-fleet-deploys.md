# Signed Fleet Deploys

**Date researched:** 2026-06-10
**Status:** Phase B implementation in progress. Host deploy verification is not
enabled yet; doc1 bot base verification is enabled by this slice and requires a
seeded bot anchor before the first scheduled run.
**Related:** #235, #270, #232

This repo is moving from "whoever can update `master` can deploy the fleet" to
"every deployed commit must be SSH-signed by a key listed in the running host's
closure." The forge remains untrusted infrastructure: hosts trust the signed
history, not GitHub or Forgejo.

## Current State

Landed in the first implementation slice:

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

Not yet landed:

- `fleet-update` verify-then-switch for host deployments.
- Freshness alerting from signed heartbeat semantics.
- Forgejo write-root cutover.

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

If `~/.gitconfig` still exists, Home Manager warns because Git reads it before
`~/.config/git/config` and it can override the declarative signing config.
Check that GitHub credential helpers made it into `~/.config/git/config`, then
remove the legacy file on that machine.

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
manually.

1. Stop the timer first:

   ```sh
   sudo systemctl disable --now nixos-upgrade.timer
   ```

2. Fix from a local checkout on the affected host. Follow the repo rebuild
   safety rules: check `hostname`, `date`, `git fetch`, and `git status -sb`
   before any `nixos-rebuild switch`.
3. Deploy the local fix.
4. Push the signed fix to the normal write root.
5. Re-run the signed fleet update path or, after U5 lands, re-anchor with the
   explicit expected SHA.
6. Re-enable the timer:

   ```sh
   sudo systemctl enable --now nixos-upgrade.timer
   ```

Stopping the timer is load-bearing. Otherwise the next nightly update can
revert the local dirty deployment.

## Rolling Bot Failure

This is for failures in `rolling-flake-update.service` on doc1, not a host
`nixos-upgrade` failure.

1. Stop the bot timer first:

   ```sh
   sudo systemctl disable --now rolling-flake-update.timer
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
6. Re-enable the timer:

   ```sh
   sudo systemctl enable --now rolling-flake-update.timer
   ```

## Key Add And Remove

Add:

1. Generate the private key on the machine that will use it.
2. Commit the public key to `hosts.nix`, signed by an already trusted key once
   enforcement is live.
3. Wait until every NixOS host has deployed a closure containing the new
   allowed-signers file.
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

1. Freeze writes to the repo.
2. Revoke that identity's push credentials on Forgejo and GitHub.
3. Land an exact key-removal commit signed by a different trusted key.
4. Deploy that commit fleet-wide.
5. Verify the stolen public key is absent from every host's
   `/etc/fleet-update/allowed_signers`.
6. Unfreeze writes.

If the whole trusted key set is suspect, use the break-glass local deploy path
instead of relying on the old signers list.

## History Rewrite Or New Root

Do not silently trust a new signed root. After U5 lands, bootstrap and history
rewrite recovery must use an explicit expected SHA:

```sh
fleet-update --accept-new-root <expected-sha>
```

Use this only after independently confirming the rewritten history. A signed
old replay or unrelated signed side branch must not become the new anchor by
accident.

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
