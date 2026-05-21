# nixosconfig

A flake-based NixOS + Home Manager configuration that started life as a
dotfiles repo and quietly turned into the homelab. Every machine I own —
desktop, laptop, WSL, and a fleet of VMs running on Proxmox — boots
from this repo.

This README is a showcase of the cool bits, not a usage guide.

## The headline trick: one-line service deploys

A service module looks like this:

```nix
homelab.services.immich.enable = true;
```

That single line wires up:

- **DNS** — `immich.ablz.au` synced to Cloudflare via API on every
  rebuild.
- **Split-horizon routing** — resolves to the host's LAN IP from inside
  the network (no hairpinning), Cloudflare's IPs from outside, the
  tailnet IP if the service is marked `tailscaleOnly`.
- **TLS** — Let's Encrypt cert via DNS-01, auto-renewing.
- **Local nginx reverse proxy** — per-host nginx bound to either the
  LAN IP or the tailnet IP, websocket headers and `client_max_body_size`
  per vhost.
- **Uptime monitoring** — a Uptime Kuma HTTP monitor provisioned via
  Kuma's API.
- **Deep probes** — optional push-style probes for "the service is
  responding 200 but doing the wrong thing" failures.
- **Log alerting** — per-service `errorPatterns` (LogQL) turn matching
  Loki log lines into alerts.
- **Logs / metrics / traces** — every host ships to a self-hosted LGTM
  stack (Loki + Grafana + Tempo + Mimir) running on doc2.

Each piece is its own module (`homelab.localProxy`, `homelab.monitoring`,
etc.); a service module just declares the inputs and the platform wires
the rest. The full module-authoring spec lives in
[`docs/wiki/nixos-service-modules.md`](docs/wiki/nixos-service-modules.md).

## Autoupdates that don't fight the user

Every host runs a nightly `nixos-rebuild switch` from GitHub. The
interesting part is everything that had to be engineered to make it
**reliable in the real world**:

- **AC power gate** — laptops skip the upgrade if running on battery.
- **WiFi SSID allowlist** — laptops only upgrade on trusted networks.
- **RTC wake from suspend** — desktops set a timer that wakes the
  machine from S3, runs the upgrade, then lets logind put it back to
  sleep automatically.
- **Lid-close inhibitor** — on laptops, the upgrade unit acquires a
  `handle-lid-switch` inhibitor so closing the lid mid-rebuild doesn't
  cut power to a half-activated system.
- **Resume ordering** — the unit runs `After=` the suspend services and
  waits for logind to declare resume complete before starting, so it
  doesn't race a not-yet-ready network.
- **60-minute timeout** — stuck activations don't hang forever; they
  fail, roll back, and ping Gotify.
- **`claude -p` diagnosis** — on failure, an LLM reads the journal and
  writes a human-readable diagnosis to Gotify instead of a raw stack
  trace.

The rolling flake-update unit (runs on doc1 at 22:15 AWST) pushes new
inputs to `master`; each host pulls the GitHub flake on its own
schedule. No CI/CD pipeline, no `--target-host` over flaky links — each
host self-heals from GitHub.

## Tailscale-share sidecars

For services that need to be reachable on a separate tailnet (e.g. a
friend's tailnet, or a vendor share), the `tailscaleShare` pattern spins
up a per-service pair: a Tailscale sidecar with its own auth key and
hostname, and a Caddy sidecar bound to that sidecar's tailnet IP. Each
shared service becomes its own tailnet node — no broad network exposure.

## hosts.nix as the single source of truth

`hosts.nix` is the only place that knows about the fleet. Each entry
declares:

- Identity (hostname, ssh alias, user, home dir)
- Trust (SSH host key, authorized keys, master fleet identity)
- Syncthing device ID
- Tailscale IP and LAN IP

A factory in [`nix/lib.nix`](nix/lib.nix) reads it and produces NixOS
systems or standalone Home Manager configs. Add a host entry, drop in a
`configuration.nix` and `home.nix`, rebuild — that's it.

## Desktops and the shell

For graphical hosts (epimetheus, framework), the Home Manager side
brings a full desktop: pick **Hyprland** or **GNOME** per host, with
the rest of the stack (waybar, fuzzel, wallpapers, theming, audio,
fonts) configured to match. Headless hosts skip all of it.

The CLI environment is fully configured too — zsh + starship,
direnv, atuin, fzf, neovim (via `nvchad4nix`), tmux, the lot. Every
machine, from the desktop to the wsl box to the headless service VMs,
gets the same shell.

## Other things worth mentioning

- **Secrets** — sops-nix with age, per-host keys, all encrypted in-repo.
- **Shared nix binary cache** — doc1 runs `nix-serve`; the rest of the
  fleet pulls from it. Saves rebuilds on every machine.
- **Self-hosted CI** — GitHub Actions runners on the fleet, sharing the
  binary cache with dev workstations.
- **Containers** — most stacks are native NixOS modules now; the
  remaining ones use either the `oci-containers` wrapper (autoupdate +
  autoheal via `homelab.podman`) or `mk-pg-container` (per-service
  Postgres in an isolated systemd-nspawn machine).
- **AI integration** — `.mcp.json` for MCP servers (pfsense, unifi,
  homeassistant, loki, mcp-nixos), a `claude-code` home-manager module,
  episodic memory synced fleet-wide via Syncthing.
- **NFS watchdog** — services that depend on NFS mounts get restarted
  when the mount comes back from a network blip, instead of going
  zombie.
- **`nix flake check`** evaluates every host configuration on every
  push; broken configs never reach a machine.

## Fleet

- **epimetheus** — desktop workstation
- **framework** — Framework 13 laptop (hibernation, AC-power-gated
  updates)
- **wsl** — Windows Subsystem for Linux, full NixOS
- **proxmox-vm** (doc1) — main services VM, binary cache, GitHub Actions
- **doc2** — service appliance VM (immich, paperless, mealie,
  cratedigger, slskd, musicbrainz, kopia, uptime-kuma, the LGTM stack…)
- **igpu** — media transcoding VM with AMD iGPU passthrough
- **dev** — sandbox dev VM
- **cache** — pull-through nix cache
- **caddy** — a small server, Home Manager only

Hypervisors: **prom** (Proxmox, 192.168.1.12) for the VMs, **tower**
(Unraid, 192.168.1.2) for NAS + a few docker stacks the flake doesn't
manage.

## Try it

```bash
nixos-rebuild switch --flake github:abl030/nixosconfig#<hostname>
```

That's the same command every host runs every night.
