---
name: relay-push
description: Land a dev box's local commits onto Forgejo master by relaying them through the doc1 bastion. Dev boxes (epi, framework) hold NO push token by design — doc1 is the sole writer. The skill fetches the dev box's commits over SSH, verifies each is signed by a hosts.nix key, rebases them onto current master, security-reviews every diff against least-privilege, then pushes ONLY after the human says "go". Trigger phrases include "pull commits from epi", "pull from framework", "land epi's commits", "push epi's work", "relay epi", "get epi's commits up", "push the dev box commits", "gated push".
version: 1.0.0
---

# Relay Push — land a dev box's commits through doc1

**Why this exists.** Dev boxes sign commits but cannot push to the deploy root.
If every dev box could push, one popped box = a signed-and-deployed fleet
takeover overnight (the signing key lives on the same box, so signing is no
defence). So the write credential lives ONLY on doc1, and the human reviewing a
diff before approving the push is the real security gate. Full rationale +
the FIDO-touch endgame: `docs/wiki/infrastructure/dev-box-gated-push.md`.

**Where this runs:** doc1 (`hostname` == `proxmox-vm`) ONLY. doc1 is the only
host that holds the Forgejo push token AND can SSH into siblings (bastion).

**The hard rule:** NEVER push before the human explicitly says "go". The whole
point is a human reviews the diff. An auto-relay would buy zero security.

---

## Preconditions

```bash
hostname                                   # must be proxmox-vm (doc1)
ls -l /run/secrets/forgejo/nixbot-token    # the push token must exist here
git -C ~/nixosconfig status -sb | head -1  # doc1 should be on master == origin/master
```
If doc1's master is ahead/behind origin/master, reconcile that first (a relay
assumes doc1's `origin/master` ref is the true, current Forgejo tip).

## 1. Reach the dev box and see what it has

doc1 → sibling SSH. Reachability gotcha (observed 2026-06-21): the SSH alias and
the Tailscale IP can both time out while the **LAN IP works**. Tailscale status
may also show stale/duplicate nodes (e.g. an offline `epimetheus-vm` next to the
live `epimetheus`). Find the live address, prefer LAN.

```bash
tailscale status | grep -i <host>          # find the ACTIVE node + its IPs
# try in order until one answers, e.g. epi: LAN 192.168.1.5 worked when ts timed out
ssh -o BatchMode=yes -o ConnectTimeout=5 <user>@<addr> \
  'hostname; git -C ~/nixosconfig log --oneline origin/master..HEAD; git -C ~/nixosconfig status -sb | head'
```
- `<user>` is the host's user from hosts.nix (abl030 on epi/framework, nixos on wsl).
- Only **committed** objects relay. A dirty working tree, `__pycache__`, an
  uncommitted `.mcp.json`, etc. stay on the dev box — note that, don't chase them.

## 2. Pull the commits into doc1 (no working-tree pollution)

```bash
cd ~/nixosconfig
git fetch origin master                                            # refresh TRUE Forgejo tip
git fetch "ssh://<user>@<addr>/home/<user>/nixosconfig" <branch>:refs/incoming/<host>
BASE=$(git merge-base origin/master refs/incoming/<host>)
```

## 3. Identify the real commits — inspect EACH one, not the range diff

The dev box is usually **behind** master (it drifts). So `git diff
origin/master..incoming` is MISLEADING — it shows every commit the box is behind
on as a giant block of "deletions" (observed: a 1-file display fix looked like
1062 deletions ripping out the ACL system). That is a staleness mirage, not the
commit.

Look at each NEW commit on its own:
```bash
git log --oneline ${BASE}..refs/incoming/<host>     # the dev box's actual new commits
git show --stat <sha>                               # per-commit: files + size
git show <sha>                                      # per-commit: the real diff
```
**Compare each commit's diff to its commit message.** If the message says one
small thing but the diff does something large or unrelated (deletes modules,
touches secrets/auth/another host) — STOP and surface it to the human. This check
is the point; it caught a mislabelled commit on the first real run.

## 4. Security review every commit against least-privilege

For each new commit, scan the diff for blast-radius / least-privilege red flags
(CLAUDE.md "AUDIT FOR LEAST PRIVILEGE"):
- plaintext secrets/tokens/keys, `.env` contents, anything that looks like a credential
- world-readable file modes (`0xx[1-7]`), broadened ownership
- new network exposure: opened ports, firewall holes, `0.0.0.0` binds, new proxy routes
- new passwordless sudo / polkit grants / `fleetDeploy.role` changes
- changes to auth, image trust (pinning/digests), sops scoping, allowed_signers
- edits to OTHER hosts or shared modules when the commit claims to be host-local

If anything trips, name it explicitly in the summary. Don't paper over it.

## 5. Verify signatures + attribution

```bash
git log --show-signature ${BASE}..refs/incoming/<host>
```
Every new commit must show **Good "git" signature** by a `hosts.nix` key. Note
WHICH host signed each (that is "where the commit came from"). An
unsigned/untrusted commit will loud-fail the fleet's nightly verification — do
not relay it; surface it instead.

## 6. Rebase onto current master (re-signs with doc1's key)

Work on a temp branch so a bad relay never strands doc1's master:
```bash
git switch -C relay/<host> origin/master
git cherry-pick ${BASE}..refs/incoming/<host>      # replays ONLY the box's new commits
```
- Non-fast-forward is EXPECTED (the box was behind). Rebase/cherry-pick — NEVER
  force-push the box's branch (that would revert the commits it's behind on).
- Cherry-pick re-commits, so signing flips to **doc1's** key (signByDefault) while
  the original author is preserved. That's fine — doc1's key is in hosts.nix.
- Confirm the result is now a clean fast-forward and touches only expected files:
```bash
git merge-base --is-ancestor origin/master relay/<host> && echo "clean FF"
git diff --stat origin/master..relay/<host>
git log --oneline origin/master..relay/<host>
```

## 7. (Recommended) eval-check before it can hit the fleet

```bash
nix flake check        # eval + repo checks (sops scope, signers, bastion role, …)
```
Warm cache on doc1 makes this tolerable. At minimum the change must evaluate.

## 8. STOP — summarise and ask for "go"

Present: source host, # commits, files touched, per-commit message-vs-diff verdict,
signature/attribution, security-review result, FF status, flake-check result.
Then ask the human to approve. **Do not push yet.**

## 9. On "go" — push from doc1, verify, clean up

```bash
git -C ~/nixosconfig -c "http.extraHeader=Authorization: token $(cat /run/secrets/forgejo/nixbot-token)" \
  push origin relay/<host>:master
git fetch origin master
git rev-parse --short HEAD origin/master           # confirm tip moved to our commit
# tidy doc1's local state + temp refs
git switch master && git merge --ff-only relay/<host> && git branch -D relay/<host>
git update-ref -d refs/incoming/<host>
```
Never echo the token. The `-c http.extraHeader` form is the same mechanism the
rolling-flake-update bot uses (header on push only, never in the saved remote).

## 10. Tell the dev box to resync

The dev box's local branch is now a diverged dead-end (its old commit was
replaced by the doc1-signed cherry-pick). On the dev box:
```bash
git fetch && git reset --hard origin/master
```
The change is in master, so this is safe and drops the stale branch.

---

## Deploy is separate

This skill only lands code on Forgejo master. To actually roll it onto hosts,
use the **service-deploy** skill / `fleet-deploy <host>` (see CLAUDE.md).

## Notes / exceptions

- **wsl** keeps its own push token (USB FIDO can't pass into WSL) — it doesn't
  need relaying, though you can relay it like any sibling if you prefer.
- **doc1** is the one unattended writer (the 23:00 bot). It never relays.
- **Break-glass:** if a future FIDO-touch key is lost, this relay IS the fallback
  path — doc1's token still works.
