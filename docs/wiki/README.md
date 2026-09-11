# Wiki

Internal knowledge base for research findings, architectural decisions, and operational knowledge that doesn't belong in code comments or CLAUDE.md.

## Structure

- `claude-code/` — Claude Code features, plugins, skills, bugs, workarounds
- `infrastructure/` — Network, VMs, storage, monitoring
- `services/` — Container stacks, integrations, service-specific docs

## Index

### Top-level

- [agent-operations](agent-operations.md) — primer for external agents (paperless, accounting/beancount): module map, edit/deploy workflow, secrets layout

### Infrastructure

- [fleet-deploy-and-sibling-lockdown](infrastructure/fleet-deploy-and-sibling-lockdown.md) — doc1-bastion deploy trigger (`fleet-deploy`, forced-command + polkit, no sibling sudo) + sibling sudo lockdown (`sudoPasswordless = false`, narrow allowlist, GTFOBin gate); per-host posture table (forgejo#2)
- [ssh-bastion-model](infrastructure/ssh-bastion-model.md) — doc1 as the sole fleet-key holder; keyless siblings, stepping-stone access, device-key entry (#270)
- [signed-fleet-deploys](infrastructure/signed-fleet-deploys.md) — every deployed commit must be SSH-signed by a `hosts.nix` key; verified `fleet-update` path, Forgejo write root (#235)
- [igpu-passthrough](infrastructure/igpu-passthrough.md) — AMD iGPU → `igpu` VM, `/dev/dri` health, kernel-reboot footgun
- [media-filesystem](infrastructure/media-filesystem.md) — mergerfs + virtiofs + tower NFS layout, where each library's media/metadata lives
- [virtiofs-database-state-exit](infrastructure/virtiofs-database-state-exit.md) — VM, virtiofs, and same-filesystem LXC database-I/O measurements; live doc2 inventory; LXC prototype, backup, and migration gates (#53)
- [igpu-io-pressure-tuning](infrastructure/igpu-io-pressure-tuning.md) — why the igpu LXC shows I/O PSI (Jellyfin keyframe/trickplay scans on raidz1), ranked reversible levers, `dropcacheonclose=false`, and what's NOT worth it (special vdev/L2ARC/SLOG/cgroup throttling)
- [nfs-over-tailscale](infrastructure/nfs-over-tailscale.md) — Tailscale readiness gap, `tailscale-wait.service`, LAN-vs-tailnet routing for tower NFS
- [tower-nfs-exports](infrastructure/tower-nfs-exports.md) — tower's NFS export inventory and who really consumes each; scoping `VMBackups`, retiring `appdata`, the still-world-readable `domains` export, and the Unraid "`/etc/exports` is generated" gotcha
- [pfsense-dns-resolver](infrastructure/pfsense-dns-resolver.md) — pfSense as the fleet DNS resolver: tunables, restart commands, ntopng/pfBlockerNG/kea2unbound footguns
- [pfsense-backup](infrastructure/pfsense-backup.md) — ACB + ZFS-pull-to-prom + dual-Kopia off-site architecture, restore procedures incl. VM-on-prom emergency play
- [dns-saturation-incident-2026-05-22](infrastructure/dns-saturation-incident-2026-05-22.md) — RCA: chronic unbound TCP/53 saturation surfaced via `rolling-flake-update`; subagent → research debugging-loop pattern
- [pfblockerng-fastly-block-incident-2026-06-07](infrastructure/pfblockerng-fastly-block-incident-2026-06-07.md) — pfBlockerNG feed false-positive blocked cache.nixos.org's Fastly /16; misdiagnosed as ISP for hours; lesson: test from the firewall itself
- [nix-mirror-failover](infrastructure/nix-mirror-failover.md) — `nix-mirror.ablz.au` fails over cache.nixos.org → SJTU → TUNA; per-request re-resolution + `ipv6=off`; disk-caches the fallback once for the fleet
- [cratesio-403-ua](infrastructure/cratesio-403-ua.md) — crates.io 403s nix's `curl/` UA; resolved by nixpkgs static.crates.io fix (#259)
- [systemd-mount-ordering-cycles](infrastructure/systemd-mount-ordering-cycles.md) — why bind mounts on NFS need `_netdev`; cycle topology and latency-bomb properties
- [netavark-2.0-dns-regression](infrastructure/netavark-2.0-dns-regression.md) — netavark 2.0.0 (nftables-only) broke rootful-podman container DNS on reboot; pinned to 1.17.x; forward path to native nftables (Forgejo #13)
- [framework-hibernate-ttm-oops-2026-07-09](infrastructure/framework-hibernate-ttm-oops-2026-07-09.md) — "failed hibernate resume" RCA: restore actually succeeded, then kernel 7.1.3 amdgpu/TTM NULL-deref froze the compositor; wifi-card swap exonerated; evidence-only subagent verification pattern
- [epi-gnome-libgvc-segfault](infrastructure/epi-gnome-libgvc-segfault.md) — "my taskbar vanished" = gnome-shell NULL-deref in bundled libgvc (pipewire card with zero profiles), GNOME's OnFailure kill switch as the visible symptom; local MR !38 patch + the flake check that tells us when to drop it
- [epi-thermals](infrastructure/epi-thermals.md) — why lm-sensors saw no motherboard fan on epi (in-tree `it87` rejects the IT8686E, `ignore_resource_conflict` for the ACPI-reserved EC at `0x0a40`), hand EC register map, and the 2026-09-07 A4-SFX cooler fault (105.9 °C, reversed fan)

### Services

- [brother-scanner-smb](services/brother-scanner-smb.md) — Brother scanner compatibility share at `\\192.168.1.6\Scans`; caddy LXC Samba, narrow tower-backed CT mount, credential recovery and verification
- [kopia-lxc](services/kopia-lxc.md) — kopia split off doc2 into CT 111: why an LXC beats a VM here (plain bind vs rbind, measured), the unprivileged-idmap problem that stops a container reading a uid-1000 repo, the bindfs fix, and the storage/mount table
- [lgtm-stack](services/lgtm-stack.md) — Loki + Grafana + Tempo + Mimir on doc2
- [jellyfin](services/jellyfin.md) — native NixOS jellyfin on igpu, VAAPI transcoding, LAN + tailnet FQDNs
- [jellyfin-mergerfs-metadata-ownership](services/jellyfin-mergerfs-metadata-ownership.md) — why the mergerfs RW metadata branches must keep gid `users` + setgid AND an owner inside igpu's LXC idmap; the 2026-09-10 root:root reset that unmounted the Music library, why prom's guard had never run, and the repair recipe
- [whisper-vad-long-audio](services/whisper-vad-long-audio.md) — why long single-pass transcription degenerates into a repetition loop, why the audio isn't at fault, why chunking and silence-splitting both fail on car audio, and the Silero VAD fix on igpu
- [voice-diary](services/voice-diary.md) — car voice notes → dated transcript pairs: phone/Syncthing/timer pipeline on doc2, why a timer and not a `systemd.path` unit on NFS, why the drop dir is read-only (the phone holds the only other copy), and why no AI is in the loop
- [youtarr](services/youtarr.md) — Youtarr OCI app on doc2, MariaDB nspawn migration, least-privilege runtime
- [tdarr-node](services/tdarr-node.md) — tdarr worker node on igpu, OCI container with `/dev/dri`
- [amp-casting-automations](services/amp-casting-automations.md) — Home Assistant casting automations
- [home-assistant-deploy](services/home-assistant-deploy.md) — HAOS topology, SSH access, tar-over-ssh YAML deploy, reload vs restart matrix
- [home-assistant-auto-update](services/home-assistant-auto-update.md) — unattended Core/OS/add-on/HACS updates, the backup chain that makes them safe, and tower's scoped `VMBackups` NFS export
- [indoor-water-meter](services/indoor-water-meter.md) — ESPHome GPIO27 reed-pulse water meter; bench-test evidence, persistence, calibration, and recovery
- [biodynamic-day](services/biodynamic-day.md) — consuming the `bd.ablz.au` moon-day API (why `day_type` is not the current type), the HA `ir-sensor` banner, and the Cullen laptop wallpaper **incl. how to remove it**
- [rtrfm-nowplaying](services/rtrfm-nowplaying.md) — RTRFM "now playing" integration
- [yoto-share](services/yoto-share.md) — `yoto.ablz.au` login-less tailnet file drop on doc2 for Yoto MYO cards; `yoto-prep` chapter-splitting, Yoto's per-track/per-card limits, and the access model

### Claude Code

- [auto-memory-directory](claude-code/auto-memory-directory.md) — persistent memory layout
- [skills-in-subagents](claude-code/skills-in-subagents.md) — skill availability inside spawned subagents
- [playwright-subagent](claude-code/playwright-subagent.md) — headed/headless browser automation via CDP-attach Chrome
- [handsfree-android-voice-input](claude-code/handsfree-android-voice-input.md) — phone push-to-talk into an agent pane: Dictate keyboard + `whisper.ablz.au` config, Termux/tmux MVP result, and why Bluetooth headset media buttons can't own PTT (implementation on unmerged `feat/handsfree-agent-voice-input`)
