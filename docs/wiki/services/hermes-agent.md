# Hermes Agent (Nous Research)

- **Date:** 2026-06-13
- **Status:** working
- **Host:** `hermes` — dedicated VM, VMID 115 on `prom` (4 vCPU / 8 GB / 50 GB)
- **Interface:** Telegram bot `@Hermes_abl030_bot`
- **Model:** `gpt-5.5` via ChatGPT Pro **Codex OAuth** (no API key)
- **Module:** `modules/nixos/services/hermes-agent.nix` · **Host cfg:** `hosts/hermes/`
- **Upstream:** github.com/nousresearch/hermes-agent

Hermes Agent is Nous Research's self-improving AI agent (the OpenClaw-successor
lineage). It executes LLM-generated code and writes/runs its own "skills", so it
runs as a locked-down OCI container on its **own** VM — the VM is the blast-radius
boundary.

## Security model (why its own VM)

See the full threat model in the module header. In short:
- **Keyless re: the fleet** (`authorizedKeys = fleetKeys`) — only the doc1 bastion
  can SSH in; a compromised agent can't move laterally.
- **Sandbox/terminal backend = `local`** (default): LLM-generated code runs inside
  the container. The podman/docker socket is deliberately **not** mounted, and the
  container is **not** `--privileged`.
- **Zero inbound exposure.** Telegram is outbound-only; the dashboard is OFF
  (`dashboard.enable = false`). Admin is via `podman exec` over the bastion.
- **Auto-updates.** Runs `:latest` and IS registered in `homelab.podman.containers`
  (`isolate = false` — sole container on its own VM), so the nightly pull-restart
  timer keeps it current like the rest of the fleet (unpinned 2026-06-19). The old
  digest-pin / "arbitrary-code executor must not self-update" stance was dropped
  as inconsistent — the nightly agent tooling has the same profile and updates too.

## State (NOT in the repo)

`/var/lib/hermes` → `/opt/data` holds `config.yaml`, `auth.json` (OAuth creds),
skills, memory, sessions, `logs/`. This is mutable self-improving state and is not
version-controlled. A from-scratch VM rebuild loses it → re-run the bootstrap
(Codex login + model pick). The only repo-managed secret is
`secrets/hosts/hermes/hermes.env` (Telegram bot token + allowlisted user IDs).

## ⚠️ The data-dir ownership gotcha (locked the agent out of /opt/data)

**Symptom (2026-06-14):** `sudo podman exec -it hermes hermes` (the interactive
TUI) crashed at startup with
`PermissionError: [Errno 13] Permission denied: '/opt/data/.env'` in
`load_hermes_dotenv`. Telegram still worked, so the gateway looked healthy.

**Cause:** the s6 image runs the supervised agent as the unprivileged `hermes`
user (**UID 10000**), and `/opt/hermes/bin/hermes` is a privilege-drop shim — a
`podman exec ... hermes` invoked as root drops to UID 10000 before exec'ing the
real binary. Our module's tmpfiles rule originally forced the bind-mount source
`/var/lib/hermes` (→ `/opt/data`) to **`root:root 0700`**. The container's init
chowns `/opt/data` to 10000 *at container start*, so it worked at first — but a
mid-run nixos activation (overnight `fleet-update`) re-ran `systemd-tmpfiles`,
which **stomped the dir back to `root:root 0700` while the container kept
running**. The gateway held the dir open and kept working; any *new* UID-10000
process (the interactive CLI, sandbox skill execution) could no longer even
traverse `/opt/data` → EACCES.

**Diagnostic tell:** as root (`podman exec`'s default) you can `ls /opt/data`
fine, but `su hermes -c 'ls /opt/data'` says permission denied — the failing
process isn't root, it's UID 10000, and the *parent dir* is root-owned 0700.

**Fix (in-tree):** the tmpfiles rule now owns the dir as the runtime uid —
`d /var/lib/hermes 0700 10000 10000` — so tmpfiles and the container agree and a
deploy can't re-lock it. Live unblock without a redeploy/restart:
`ssh hermes 'sudo chown 10000:10000 /var/lib/hermes'`. Do **not** "re-lock" it to
`root:root` thinking it hardens the box — 0700 owned by 10000 is already
owner-only (uid 10000 + host root); root ownership only re-breaks the agent.

Escape hatch for a deliberate root CLI session (writes root-owned files under
`$HERMES_HOME`, so use sparingly): the shim honours `HERMES_DOCKER_EXEC_AS_ROOT=1`
— `sudo podman exec -it -e HERMES_DOCKER_EXEC_AS_ROOT=1 hermes hermes`.

## ⚠️ The model-selection gotcha (cost real debugging time)

The user runs on a **ChatGPT Pro subscription via Codex OAuth**, not an API key.
(This is ToS-clean for OpenAI — unlike Anthropic, which explicitly bans
subscription-OAuth in third-party tools as of Feb 2026.)

The trap:
- A ChatGPT account **rejects `gpt-5-codex`** with HTTP 400
  `"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account."`
  The accepted model set **shifts** with OpenAI's entitlement churn (see openai/codex
  #19654; Hermes #23097, #17533).
- Hermes' Codex provider **defaults to `gpt-5-codex`**, so out of the box every
  message 400s.
- **`hermes config set model.default <x>` does NOT fix it** — it doesn't write the
  provider `base_url`, so the Codex provider ignores the value and still sends
  `gpt-5-codex`. Likewise forcing `-m <other>` never reaches an API call.
- **FIX = the interactive picker `hermes model`.** *Selecting* a model writes the
  full provider block (`provider` + `default` + `base_url`) that the provider
  actually honors. Pick from the LIVE list — for this Pro account, **`gpt-5.5`**
  works (the picker also offered gpt-5.4, gpt-5.4-mini, gpt-5.3-codex-spark).

Driving the picker headlessly (it needs a TTY) — from doc1 via tmux:
```sh
tmux new-session -d -s pick 'ssh -tt hermes "sudo podman exec -it hermes hermes model --refresh"'
sleep 9; tmux capture-pane -t pick -p          # read the screen
tmux send-keys -t pick Enter                   # ↑↓ navigate, ENTER selects
# flow: OpenAI → OpenAI Codex → type "1" (use existing creds) → pick gpt-5.5
```

## Runbook

- **Codex login / re-auth (one-time, device-code):**
  ```sh
  sudo podman exec -i hermes hermes auth add openai-codex --type oauth --no-browser
  # open https://auth.openai.com/codex/device, enter the code, sign in with ChatGPT Pro
  ```
- **Verify a model actually works:**
  ```sh
  sudo podman exec hermes hermes -z "Reply with exactly: OK"   # prints OK when good;
  # "no final response" == failure → check /opt/data/logs/{agent,errors}.log for the real 400
  ```
- **Change model:** the tmux picker above.
- **Update the image:** automatic — `:latest` is pulled+restarted by the nightly `homelab.podman` timer. To force now: `sudo systemctl start podman-update-containers` (or `podman pull` + `systemctl restart podman-hermes`).
- **Telegram allowlist:** `TELEGRAM_ALLOWED_USERS` in `hermes.env` (numeric user IDs);
  without it the gateway denies everyone.

## Web dashboard — https://hermes.ablz.au (tailnet-only)

Enabled via `homelab.services.hermes-agent.dashboard` + a `homelab.tailscaleShare`
pinhole (dedicated tailnet node `hermes-ui`, separate from the `hermes` host).
Tailnet-only — no LAN, no public. Gated by HTTP Basic Auth (`abl030` + the
password/secret in `hermes.env`); the login is a form at `/login`, backed by the
`HERMES_DASHBOARD_BASIC_AUTH_*` env. The Basic Auth plugin is a real
DashboardAuthProvider, so it satisfies Hermes' own non-loopback bind gate (no
`--insecure`). Deliberately **no Uptime Kuma monitor** (`monitorEnable = false`)
so the locked-down VM holds no Kuma API credential.

Gotchas hit while wiring this (all fixed in-tree):
- **ts sidecar auth.** The `tailscale/tailscale` image kills `tailscale up` after
  ~60s without an auth key and restarts (regenerating the node key), so the
  interactive login URL churns and is hard to catch. It CAN land if you approve
  fast (state then persists and it stays up), but a pre-generated reusable
  **auth key** (admin console → `authKeySecret`) is the reliable path for next time.
- **ACME DNS-01 from inside the netns.** caddy's own propagation *precheck* can't
  see the public `_acme-challenge` TXT (it resolves via the podman/tailnet path),
  so issuance hung on "timed out waiting for record to propagate". Fix in the
  shared `tailscale-share.nix` Caddyfile: `resolvers 1.1.1.1 1.0.0.1` +
  `propagation_delay 30s` + `propagation_timeout -1` (disable the blocking
  precheck; Let's Encrypt validates against Cloudflare's authoritative NS, which
  is clean). Also: failed attempts leave stale `_acme-challenge` TXT records —
  if dozens pile up, purge them via the Cloudflare API before retrying.
- **Secret rotation restart.** `podman-hermes` restartTriggers key on the secret's
  ENCRYPTED source (content-addressed), not `/run/secrets/...` (constant) — else
  changing a credential's *content* never restarts the container and it keeps
  stale env (symptom: dashboard refuses to bind because the Basic Auth vars
  "aren't set" even though they're in `/run/secrets/hermes-env`).

## Capability tiers: Telegram = read-only, TUI = full operator (in progress)

Direction (2026-06-14): make Hermes a real homelab operator without the cage
making it useless. The model is **capability follows exposure**, enforced by
*credential availability*, not by asking the LLM to behave:

- **Telegram gateway = read-only by construction.** The always-on gateway env
  holds only `TELEGRAM_BOT_TOKEN` + the dashboard Basic-Auth secret — no Forgejo
  token, no deploy key, no SSH identity, not even an LLM API key (it uses Codex
  OAuth via `auth.json`). So a prompt-injected Telegram message *physically*
  cannot deploy, push, or SSH the fleet. **Never add a prod credential to this
  env.** Loki (`https://loki.ablz.au`) is unauthenticated and reachable from the
  container, so read-only triage needs zero creds.
- **TUI from the doc1 bastion = full operator.** (Planned next.) Launch the TUI
  with SSH agent forwarding so the *session* borrows your agent — which holds
  your signing key + the fleet/deploy key — letting it sign commits as you, push
  to Forgejo, and `ssh doc2 sudo fleet-update`, with **no standing key on the
  hermes box**. Close the session → capability evaporates. The cratedigger
  ship/verify loop (bump `cratedigger-src` input → sign+push Forgejo →
  `fleet-update` doc2 → check `{host="doc2", unit=~"cratedigger.*"}` in Loki) is
  the target workflow.

### Agent-forwarding mechanism (validated 2026-06-14)

No container/image change is needed: `/opt/data` is already a writable bind
mount (= `/var/lib/hermes`), so the forwarded agent socket lands at
`/var/lib/hermes/.ops/agent.sock` → `/opt/data/.ops/agent.sock`. The host has
`python3` (no `socat`), so the bridge is `hosts/hermes/operator/agent-bridge.py`
(runs as root on the hermes host; listens on a uid-10000-owned socket, proxies
to the operator's forwarded `$SSH_AUTH_SOCK`; socket removed on exit). Then
`podman exec -e SSH_AUTH_SOCK=/opt/data/.ops/agent.sock -it hermes hermes`.

**⚠️ CRITICAL — isolate the agent or you leak the fleet key.** Reaching hermes
authenticates with `~/.ssh/id_ed25519` (the fleet key →
`/run/secrets/ssh_key_abl030`). A naïve `ssh -A hermes` plus the default
`AddKeysToAgent yes` **injects the fleet key into the very agent you forward** —
verified: the container then saw both `hermes-deploy` *and* `master-fleet-identity`,
i.e. a prompt-injectable code-executor got the keys to the whole fleet. The
launcher MUST connect with the fleet key from file only and never add it to the
agent:
`ssh -A -o AddKeysToAgent=no -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 hermes …`
With that, the forwarded agent carries ONLY the scoped operator keys (verified:
container sees just `hermes-deploy`). Build the scoped agent fresh per launch
(`ssh-agent` + `ssh-add` exactly the operator keys) — never forward your
personal/login agent.

**Residual risk (accepted for watched sessions):** the bridged socket is
reachable by any uid-10000 process in the container — including the always-on
gateway — for the *life of the session*. A separate-uid/container split would
close it; for now the mitigation is "only launch while you're driving it."

**The new key:** `hermes-deploy` (`SHA256:YKwpC2fG7X5/yEjDKFMFclaFi04O87/owaEIrRcTiYI`,
comment `hermes-deploy@operator`). Private half on doc1 only (→ sops
`secrets/hosts/proxmox-vm/`, pending); public half → a forced-command grant on
doc2 (`command="…fleet-update",restrict,from="100.64.0.0/10,192.168.1.0/24"`,
mirroring the `marker-convert` / `gwm-archiver` trigger-key pattern). **Live on
doc2** (`homelab.services.hermesOperatorDeploy`, commit `16ae3dd4`) and verified
end-to-end: the hermes container, via ONLY the forwarded key, ran `fleet-update
--dry-run` on doc2; an arbitrary command (`cat /etc/shadow`) was refused.

### Launch & status

Launcher: the **`hermes-operator`** command on doc1 (installed by
`homelab.services.hermesOperatorLauncher`; source `hosts/hermes/operator/`).
Builds the scoped agent from the sops-deployed keys, forwards it with fleet-key
isolation, execs the TUI. Inside the session: deploy doc2 with
`ssh abl030@192.168.1.35 deploy` (check with `dry-run`); `git push` signs as you
and pushes over `ssh://git@git.ablz.au:2222`.

- **Working (tested):** deploy doc2 (forced-command key); **sign** commits as
  abl030 (forwarded `git-signing` key — the container signed a commit OK); verify
  via read-only Loki; Telegram read-only triage. The launcher forwards 3 scoped
  keys: `hermes-deploy`, `hermes-forgejo`, `id_ed25519_git_sign`.
- **Session git identity** (set imperatively in `/opt/data`, uid 10000 — recreate
  after a VM rebuild): `user.email=abl030@gmail.com`, `gpg.format=ssh`,
  `user.signingkey=key::<git-signing pub>`, `commit.gpgsign=true`, and
  `url."ssh://git@git.ablz.au:2222/".insteadOf "https://git.ablz.au/"` (Forgejo's
  SSH server is on :2222, separate from host sshd on :22).
- **Pending — Forgejo push-key registration (manual, your account):** add the
  `hermes-forgejo` public key to Forgejo — simplest as an account SSH key, or as
  per-repo *write* deploy keys on nixosconfig + cratedigger for tighter scope.
  Until then the session signs but can't push.
- **The nix gap — closed.** The container still has no nix, but
  `ssh abl030@192.168.1.29 bump-cratedigger` (a forced-command on doc1, the
  `hermes-deploy` key again) re-pins `cratedigger-src` to its latest upstream and
  pushes the lockfile bump to Forgejo master, **signed by the rolling bot key**
  (`nix bot <acme@ablz.au>` — the caller never holds it, only triggers the
  re-pin; verify-before-push gate). The session then `ssh abl030@192.168.1.35
  deploy`s doc2. So the cratedigger ship loop (for code already on
  `github:abl030/cratedigger`) is closed **without** needing the Forgejo push
  key. cratedigger-bump source: `hosts/hermes/operator/cratedigger-bump.sh`.
- **Hermes knows its powers** via the `homelab-operator` skill
  (`hosts/hermes/skills/homelab-operator/`): the exact deploy/bump/push commands,
  the two loops, and guardrails (only works in an operator TUI; verify after
  deploy; deploy doc2 + bump cratedigger only). Pairs with `homelab-triage`.
- **Hardening (done):** the operator keys are sops-scoped to doc1
  (`secrets/hosts/proxmox-vm/hermes-{deploy,forgejo}-key`, decryptable only by
  doc1 + editor + break-glass) and deployed via
  `homelab.services.hermesOperatorLauncher`, which also installs the
  `hermes-operator` command; the agent-bridge is baked into the hermes host at
  `/etc/hermes/agent-bridge.py`. Remaining imperative bit: the container git
  identity (commands documented above for rebuild recovery).

### `homelab-triage` skill (read-only Loki triage)

The Telegram read-only win: `hosts/hermes/skills/homelab-triage/SKILL.md` (repo
source) installed at `/opt/data/skills/devops/homelab-triage/`. Encodes the Loki
query recipes (fleet host map, AWST time handling, `curl -G --data-urlencode`,
`python3` parsing since `jq` is absent) so "triage overnight / why is X down"
works from the phone, read-only.

**Adding/maintaining a hand-authored Hermes skill (gotchas learned):**
- Drop `SKILL.md` into `/opt/data/skills/<category>/<name>/`, owned `10000:10000`.
  Agent-created skills are enumerated by **directory scan at session start** — a
  live `hermes -z "…"` session rebuilds `.skills_prompt_snapshot.json` and
  surfaces it. A gateway *restart alone does NOT* rebuild the snapshot.
- `hermes skills install` is **registry/HTTP-only** (no `file://` / local path) —
  you cannot install a local skill that way; just place the dir.
- **Pin it:** `hermes curator pin <name>`. The curator auto-archives unpinned
  agent-created skills after 90d unused; pinning exempts it. `.bundled_manifest`
  only tracks *bundled* skills (hash-based update detection), not agent-created
  ones — absence there is expected and harmless.
- Keep the canonical copy in the repo (`hosts/hermes/skills/`); `/opt/data` is not
  version-controlled and a VM rebuild wipes it.

## Fresh-host quirks (already handled, noted for the next VM)

- **Tailscale:** a brand-new host needs a one-time `tailscale up` approval to join the
  tailnet, else `tailscale-wait.service` fails activation (and would page nightly).
- **home-manager / sops race:** sops-nix creates `~/.local/share/atuin/` as **root**
  during activation, which blocks home-manager from creating `~/.local/state/nix/
  profiles` → `home-manager-<user>.service` fails the whole switch. Existing hosts
  dodged it because `~/.local` was created abl030-owned long ago. Fixed declaratively
  with a tmpfiles rule in `hosts/hermes/configuration.nix` (pre-owns `~/.local`).
- **switch-inhibitor check:** on the *very first* `nixos-rebuild switch` (while still
  on the generic template image) the new `switch-to-configuration` inhibitor check
  chokes (`jq: Expected JSON value`). Bootstrap with `switch-to-configuration boot`
  + reboot once; subsequent switches on our own generation are fine.
- **NIC rename:** the template boots `eth0`; our config uses predictable names
  (`ens18`) → a new DHCP lease on first boot into our config (IP changed .161 → .162).
