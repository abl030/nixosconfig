# Dev-box gated push (and the FIDO-touch endgame)

- **Date:** 2026-06-21
- **Status:** interim model LIVE (relay through doc1); FIDO-touch model PLANNED (no hardware yet)
- **Related:** signed-fleet-deploys (#235), sibling lockdown (forgejo#2), `.claude/skills/relay-push/`
- **Supersedes the direction of:** the "dev boxes may hold a plaintext Forgejo write token" stance (that was only ever wsl; do NOT extend it)

## The problem

The fleet auto-deploys the tip of Forgejo `master` every night: `fleet-update`
fetches Forgejo, verifies every commit in range is SSH-signed by a key in
`hosts.nix`, then builds and switches. Dev boxes (epi, framework, wsl) **sign
commits by default with a key that is in `hosts.nix`'s allowed_signers**.

Put those two facts together: if a dev box also holds a credential that can push
to `master`, then **one compromised dev box = whole-fleet takeover by morning.**
Malware (or an evil maid) on the box writes a commit, signs it with the on-box
key — which verifies, it's a trusted fleet key — pushes to master, and every host
deploys it overnight.

**Commit signing does NOT defend this.** Signing only stops tampering by someone
*without* a fleet key (a popped Forgejo host, a MITM, the frozen GitHub mirror).
Against a compromised *signing host*, signing is theatre — the attacker holds the
key. Co-locating the signing key and a push credential on a roaming workstation
collapses both into a single blast radius. This is exactly the
"post-compromise lateral movement" threat model in CLAUDE.md, and it is why the
fleet was funnelled through the doc1 bastion in the first place.

## The irreducible truth

You **cannot** have both (1) a dev box that pushes auto-deploying code with no
human in the loop, and (2) safety against that dev box being compromised. If
Claude-on-epi can push to the deploy root unattended, so can malware-on-epi.

So a human (or genuine out-of-band check) MUST sit between "a dev box produced a
change" and "the fleet deploys it." The only design question is **where the human
stands to approve, and how cheap we make it.** Crucially, an *automated* relay
through doc1 (fetch → check signature → check fast-forward → push) buys **zero**
security — it has the same blast radius as a token on the dev box. The security
comes only from a **human reading the diff** before it can deploy.

## Interim model (LIVE): relay through doc1

- Dev boxes hold **no** push token. They commit locally; they cannot push.
- doc1 is the **sole writer** to Forgejo master (it holds the nixbot token at
  `/run/secrets/forgejo/nixbot-token`) and is the bastion that can SSH into siblings.
- To land a dev box's work: on doc1, run the **`relay-push`** skill — it fetches
  the box's commits over SSH, inspects each commit (message-vs-diff), verifies
  signatures + attribution, security-reviews against least-privilege, rebases onto
  current master, and pushes **only after the human says "go".**
- The human-reads-the-diff step is the gate. First real run (2026-06-21) it
  immediately earned its keep: a commit labelled "add fix-displays command" showed
  a 1062-line diff against master. That was a **staleness mirage** (the box was 8
  commits behind, so the range-diff rendered missing commits as deletions) — the
  commit itself was a clean 1-file change — but the review is exactly what
  distinguishes "mislabelled/dangerous" from "just stale". Always inspect
  per-commit, never the range diff against master.

Cost: the human has to be at doc1 to approve. Accepted for now.

## Endgame (PLANNED): FIDO touch-on-push

The clean fix is to make pushing require a **physical touch on a hardware FIDO2
key**, so malware/evil-maid simply cannot push — the secret lives on a key in the
user's pocket, not on disk.

- **Separate the two keys.** Commit signing stays a normal on-disk ed25519 (no
  touch, Claude commits freely, fleet-update's signature check unchanged — that's
  attribution). **Pushing** uses an `sk-ssh-ed25519` (FIDO) key as the SSH
  transport credential to Forgejo (port 2222). Each `git push` = one SSH auth =
  one **touch**. That is "touch per push, not per commit".
- **Split the remote** so only pushing costs a touch: fetch over HTTPS
  (anonymous, public repo, no touch); push over SSH with the sk key.
  `remote.origin.url` = HTTPS, `remote.origin.pushURL` = `ssh://git@git.ablz.au:2222/...`.
- **This retires the relay** — dev boxes push directly to master again, but each
  push is hardware-gated. No doc1 login, no protected-branch/PR machinery.
- **Touch vs fingerprint:** a touch-only key (YubiKey 5 / Nitrokey 3 / SoloKey 2)
  proves *a human is present*; a fingerprint key (YubiKey Bio) proves *which*
  human. Fingerprint matters most for an always-on desktop where the key lives in
  the slot (presence-only would let an evil maid just press it). If the user
  **carries** one key and plugs in per push, touch-only already defeats the evil
  maid (they don't have the key); the fingerprint becomes insurance against losing
  it / leaving it plugged in.
- **Residual hole:** a touch authorises whatever is in the push *range*, so
  malware could piggyback a commit under your branch. "Glance at what you're
  pushing, then touch" stays procedural. Touch = human present; glance = human
  approves.

### Deliberate exceptions
- **doc1** stays token-based — the 23:00 rolling bot is unattended and can't touch
  a key. doc1 is the one trusted unattended writer, protected differently
  (locked, key-only SSH, bastion).
- **wsl** can't reach a USB FIDO device without ugly passthrough, so it keeps a
  token / relay posture. Known carve-out.
- **doc1's token is the break-glass** for a lost/broken FIDO key — you fall back
  to the `relay-push` path until a replacement arrives. No lockout, so a single
  key is acceptable (a backup key is optional, not required).

## Hardware decision (open)

No YubiKeys owned yet (2026-06-21). Plan: buy **one** key and carry it, plug in
wherever (per-box non-resident sk handles, all backed by the one authenticator).
Leaning YubiKey Bio (FIDO Edition — FIDO2 is all we need) for the safety net, or a
cheaper touch-only key if carried reliably. **The laptop's built-in fingerprint
reader does NOT work for this** — on Linux it's a `fprintd` device, not a FIDO2
authenticator OpenSSH's sk middleware can use; an external hardware key is
required regardless. Revisit `hosts.nix` / home-manager wiring (~20 min) when the
key arrives.
