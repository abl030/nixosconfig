# Agent research browser and automatic site logins (doc1)

**Added:** 2026-10-03
**Status:** browser units deployed; logins inert until the operator creates the
Secrets Manager machine account and stores its token (steps below).
**Module:** `hosts/proxmox-vm/agent-browser.nix`
**Secret:** `secrets/hosts/proxmox-vm/bitwarden-agent-research.yaml` (key `token`)
→ `/run/secrets/bitwarden/agent-research-token` (abl030, 0400)
**Operator docs / helper:** `~/agents/BROWSER.md`, `~/agents/bin/agent-login`,
`~/agents/bin/agent-login.sites.json` (private `abl030/agents` repo)

## What it is

The family-history agents in `~/agents` drive a real Chrome through the
`chrome-devtools` MCP, attached to `127.0.0.1:9222`. doc1 has no screen, so the
Chrome is *headed* on a private Xvfb display `:99` (never `--headless`: a
`HeadlessChrome` UA is bot-blocked on sight, see the trap note in BROWSER.md).

Two pieces live here:

1. **`agent-xvfb.service` + `agent-chrome.service`** (abl030 user units, pinned
   by `ConditionUser`). Linger (configuration.nix) starts them at boot. Same
   profile (`~/.cache/chrome-devtools-mcp/chrome-profile-stable`), port and
   flags as the old ad-hoc `~/agents/bin/agent-chrome`. The packages are
   referenced from the units, so the system closure GC-roots them; the old
   `~/.cache/agent-chrome/gcroots` symlinks are obsolete after the switch-over.
   Each unit has an `ExecCondition` that *skips* it when an ad-hoc Xvfb still
   holds `:99` or something already answers on 9222, so deploying never fights
   a browser in use.
2. **The Secrets Manager token** for `agent-login`, which fetches a site's
   credential with `bws` and types it into the login form over CDP. The
   password never enters an LLM context; the agent only sees one status line.

Chrome's own password manager is disabled by policy
(`programs.chromium.extraOpts.PasswordManagerEnabled = false`) so typed
credentials are not saved into the profile or autofilled into pages agents read.

## Why Bitwarden Secrets Manager

The operator already keeps the sops break-glass key in Bitwarden and wanted the
logins there too. Options considered (2026-10-03):

| Option | Verdict |
|---|---|
| **Secrets Manager machine account + `bws`** (chosen) | The token can read only the projects granted to it (one project, read-only). It is not the personal vault and holds no master password. It can be revoked or expired on its own. The operator edits credentials in the Bitwarden web app with no deploy. `bws` is in nixpkgs (unfree, allowed fleet-wide). Requires a Bitwarden *organization* (the free org + Secrets Manager free tier is enough). |
| `bw` CLI with a personal API key | The API key logs in to the **whole personal vault**, and unlocking needs the master password on disk. Rejected. |
| `rbw` | Same personal-vault scope; wants the master password through pinentry. Rejected. |
| `bw` as a second, dedicated Bitwarden user sharing one org collection | Works, but means another account whose master password sits on doc1. Heavier than a machine account and no better scoped. |
| Plain sops secrets per site | Viable fallback if Secrets Manager is ever unavailable: same on-host exposure, but every credential change becomes a commit + deploy and old ciphertexts stay in git history. |

## Threat model

- **Anything that can run as abl030 on doc1 can obtain these credentials**: it
  can read the token file and call `bws`, read Chrome's cookie jar, or attach to
  9222 and watch the login. That covers every agent session on doc1. The design
  stops the password landing in **transcripts and model context** by accident.
  It does not defend against a compromised abl030.
- Therefore the `agent-research` project holds **only low-value research-site
  logins** (FamilySearch, Ancestry, Findmypast, similar). Never banking, email,
  the Bitwarden account itself, Forgejo, or anything that can reset other
  passwords. Use a unique password per site.
- The machine account has **read-only** access to that one project and nothing
  else. It cannot see the personal vault or create or modify secrets.
- The DevTools port binds `127.0.0.1` only. Off-host access is the operator's
  `ssh -L 9222:127.0.0.1:9222 doc1`.
- While `agent-login` runs, its window's network log (the login POST body) is
  visible to any other CDP client, including the MCP. Agents are told never to
  inspect the agent-login window or its network requests. It closes the window
  when it finishes, except on a "needs-human" outcome.
- After a rejected login, `agent-login` backs off for an hour per site, so a
  looping agent cannot lock the account.

## Operator setup (one-time)

1. Bitwarden web vault → Secrets Manager (create a free organization first if
   there is none). Create project **`agent-research`**.
2. In it, create secrets named exactly `familysearch/username`,
   `familysearch/password`, `ancestry/username`, `ancestry/password`,
   `findmypast/username`, `findmypast/password`. Add `<site>/totp` (base32 or
   `otpauth://` URI) only for a site that uses an authenticator app.
3. Machine accounts → new **`doc1-agent-research`** → Projects: add
   `agent-research` with **Can read** only → Access tokens: create one (an
   expiry such as 1 year is fine) and copy it.
4. On doc1, **in your own terminal, not through an agent**:
   `cd ~/nixosconfig/secrets && sops hosts/proxmox-vm/bitwarden-agent-research.yaml`
   and replace the `PLACEHOLDER-…` value of `token:` with the access token.
   Commit that file (ciphertext only), push, `sudo fleet-update`.
5. Test: `~/agents/bin/agent-login --check familysearch`, then
   `~/agents/bin/agent-login familysearch`.

EU-region accounts: also set `BWS_SERVER_URL=https://vault.bitwarden.eu`
in the environment (bws reads it). The default is the US cloud.

## Rotate / revoke

- **Revoke now** (suspected leak): Bitwarden → Machine accounts →
  `doc1-agent-research` → Access tokens → revoke. `agent-login` then fails with
  `bws failed … ` and does nothing else. Then rotate the site passwords
  themselves, since an attacker running as abl030 could also have read them.
- **Rotate the token**: create a new access token, put it in the sops file
  (step 4), deploy, then revoke the old one.
- **Rotate a site password**: change it on the site, update the
  `<site>/password` secret in Secrets Manager. No deploy needed.
- **Disable entirely**: set the sops value back to a placeholder (or delete the
  machine account). `agent-login` reports `not-configured`.

## Switch-over from the ad-hoc Chrome (one-time, pending)

After this module deployed (2026-10-03), the ad-hoc Chrome started by
`~/agents/bin/agent-chrome` was still running and in use, so the units were
skipped by their `ExecCondition`s. When no agent is mid-browse:

```sh
systemctl --user daemon-reload
chrome=$(pgrep -o -f -- '--remote-debugging-port=9222')   # oldest = browser process
kill "$chrome"; while kill -0 "$chrome" 2>/dev/null; do sleep 1; done   # SIGTERM flushes cookies
kill "$(tr -d ' ' < /tmp/.X99-lock)"; sleep 1
systemctl --user start agent-xvfb.service agent-chrome.service
systemctl --user is-active agent-xvfb.service agent-chrome.service
curl -s localhost:9222/json/version | grep -c HeadlessChrome   # must print 0
rm -rf ~/.cache/agent-chrome/gcroots                            # old GC-root hack
```

After a reboot the units own it anyway. `~/agents/bin/agent-chrome` starts the
unit when it exists. On doc1, nothing else should bind 9222. In particular,
nixosconfig's `scripts/playwright-chromium.sh` uses the same port with a
different profile.

## Troubleshooting

- `systemctl --user status agent-chrome` says *condition failed*: something
  already serves 9222 (or `:99`). Check `curl localhost:9222/json/version`. If
  the UA says `HeadlessChrome`, kill it.
- `agent-login` exit codes: 0 logged in, 1 logged out/rejected, 3 needs a human,
  4 not configured, 5 Chrome unreachable, 6 backing off after a failure.
- A site changed its form: `agent-login --inspect <site>` prints the form
  controls (attributes only, never values). Update the selectors in
  `agent-login.sites.json`.
