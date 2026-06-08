# sops break-glass recovery & the recipient model

**Status:** live (shipped via [#234](https://github.com/abl030/nixosconfig/issues/234), 2026-06-08). Hardens the secret layer under the [doc1 SSH bastion](./ssh-bastion-model.md) (#270).
**Written:** 2026-06-08.

## The recipient model (what can decrypt what)

Every secret in `secrets/` is encrypted to its **consuming host key(s)** plus two
universal keys. Layout *is* scope — a file under `secrets/hosts/<H>/` is
decryptable only by host `<H>` (+ the two universal keys), enforced by
`sopsRecipientScopeCheck` in `flake.nix`.

| Key | Kind | Private half lives | Role |
|---|---|---|---|
| **break-glass** `age1y6na…` | cold | **Bitwarden** secure note + **printed/QR** in the safe — on **no host** | recovery only |
| **editor** `age17uw7…` | warm | doc1 `~/.config/sops/age/keys.txt` (the `abl030` user) | edit any secret from the bastion |
| **host keys** (7) | per-host | each host's `/etc/ssh/ssh_host_ed25519_key` (→ `ssh-to-age`), root-only | that host decrypts its own secrets at activation |

There is **no separate "master" key**. The pre-#234 "Master Fleet Identity"
recipient was `ssh-to-age(ssh_key_abl030)` — the fleet SSH key in age form —
and was retired as a sops recipient in #234 (it has no decryption duty; the
fleet key is SSH-only). The editor + break-glass keys are fresh, dedicated age
keys minted in #234.

`.sops.yaml` rules: per-host-dir globs (`^hosts/<H>/`), explicit multi-host
rules (acme → doc1/doc2/igpu/wsl; uptime-kuma → doc1/doc2/igpu), a fleet-wide
rule (`nix-netrc`/`atuin-*`/`gotify.env` → all 7 live hosts), and a **fail-closed**
`.*` fallback (editor + break-glass only — a new, unruled secret deploys
nowhere until given a rule).

## Recover a secret with the break-glass key

When you've lost warm access (doc1 gone, or the editor key unavailable):

```bash
# 1. Restore the break-glass private key from Bitwarden (or the printed copy)
#    into a temp file on any trusted machine with sops + age installed.
umask 077; cat > /tmp/bg.key   # paste the AGE-SECRET-KEY-1… line, then Ctrl-D

# 2. Decrypt any secret:
env -u SOPS_AGE_KEY XDG_CONFIG_HOME=/tmp/none \
  SOPS_AGE_KEY_FILE=/tmp/bg.key sops -d secrets/hosts/doc2/immich-pgpass.env

# 3. When done:
shred -u /tmp/bg.key
```

The byte-for-byte check that the Bitwarden copy is correct:
`age-keygen -y /tmp/bg.key` must print `age1y6nasu9gplutapjne4yv0uhzrwee6ayf2mygwhphf3nty6x5xddqy4zl4h`.

## Rollback a bad re-key

A `git revert` restores the `.sops.yaml` *rules* but **not** the recipient sets
already written into the on-disk encrypted files — those carry whatever the last
`sops updatekeys` wrote. So rollback is two steps:

```bash
git revert <bad-commit>
# then re-key every affected file back to the reverted rules, driven by a key
# that can still decrypt them (break-glass always can):
( cd secrets && for f in <affected files>; do
    env -u SOPS_AGE_KEY SOPS_AGE_KEY_FILE=/tmp/bg.key sops updatekeys --yes "$f"
  done )
shred -u /tmp/bg.key
nix flake check   # sopsRecipientScopeCheck must pass before pushing
```

This path was exercised once on a throwaway file during the #234 migration.

## Reconstruct the editor key if doc1 is lost

The editor key has no off-box backup by design (break-glass reconstructs it):

```bash
# On the rebuilt doc1, mint a new editor key:
age-keygen -o ~/.config/sops/age/keys.txt    # note its age1… public
# Swap the new editor pubkey into secrets/.sops.yaml (replace age17uw7…),
# then re-key everything, driven by the break-glass key (the only surviving
# universal key until the new editor is a recipient):
( cd secrets && for f in $(find . -type f ! -name '.sops.yaml' ! -name '*.pub' ! -name 'readme.md'); do
    env -u SOPS_AGE_KEY SOPS_AGE_KEY_FILE=/tmp/bg.key sops updatekeys --yes "$f"
  done )
shred -u /tmp/bg.key
```

## Driving routine re-keys (normal operations)

From doc1, the **editor** key (its `~/.config/sops/age/keys.txt`) decrypts every
secret, so `sops edit <file>` and `sops updatekeys <file>` work directly. To
re-key the whole tree after a `.sops.yaml` change, run `sops updatekeys --yes`
over each file from within `secrets/` (the config is found relative to CWD).
sops's config discovery uses the working directory, so run re-keys from
`secrets/`, not the repo root.

## Cold-loss caveat

If **both** doc1 (the editor + every doc1 host key) **and** the break-glass copies
(Bitwarden + paper) are lost simultaneously, the secret corpus is unrecoverable —
regenerate each secret from its upstream source. This is why the break-glass key
has two independent off-box copies (online vault + offline paper).

## See also

- [SSH bastion model](./ssh-bastion-model.md) — the #270 layer this hardens; break-glass *for host access* is the Proxmox console on prom.
- `secrets/readme.md` — the sops bootstrap workflow + `updatekeys` recipe.
- [#234](https://github.com/abl030/nixosconfig/issues/234) — the recipient-scoping migration.
