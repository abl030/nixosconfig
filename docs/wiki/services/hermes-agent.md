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
- **Controlled updates.** Image pinned by digest and intentionally NOT in
  `homelab.podman.containers`, so the nightly pull-restart timer ignores it. Bump
  the digest deliberately.

## State (NOT in the repo)

`/var/lib/hermes` → `/opt/data` holds `config.yaml`, `auth.json` (OAuth creds),
skills, memory, sessions, `logs/`. This is mutable self-improving state and is not
version-controlled. A from-scratch VM rebuild loses it → re-run the bootstrap
(Codex login + model pick). The only repo-managed secret is
`secrets/hosts/hermes/hermes.env` (Telegram bot token + allowlisted user IDs).

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
- **Update the image:** bump the pinned digest in `hermes-agent.nix` (NOT auto-updated).
- **Telegram allowlist:** `TELEGRAM_ALLOWED_USERS` in `hermes.env` (numeric user IDs);
  without it the gateway denies everyone.

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
