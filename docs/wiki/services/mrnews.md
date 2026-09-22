# Margaret River News (mrnews)

Status: live on doc1 (`proxmox-vm`) at `https://mrnews.ablz.au` (LAN/tailnet only).
Updated 2026-09-23.

## Pipeline

1. Hermes cron jobs on doc1 (`~/.hermes/cron/jobs.json`, launchers in
   `~/.hermes/scripts/margaret-river-*.sh`) run the skills in
   `abl030/margaret-river-planning` (`skills/margaret-river-*/SKILL.md`).
2. A job that finds a story writes `content/posts/<file>.md` in `~/mrnews`,
   builds it, makes an SSH-signed commit and pushes `abl030/mrnews` master.
3. The job runs `scripts/publish-mrnews-post.py --post …` in the planning repo.
   That calls `mrnews-deploy`, waits for `/posts/<slug>/` to return 200 and
   sends a Gotify message ("MR News: <title>"). If the post can't go live it
   sends "MR News post NOT live: …" at priority 8 and exits 1. Sent slugs are
   recorded in `~/.local/state/margaret-river/mrnews-notified.json` so a
   re-run does not ping twice.
4. `mrnews-deploy` starts `mrnews-deploy.service` (polkit lets `abl030` start
   only that unit). The service runs as `mrnews-deploy`, fetches master into
   `/var/lib/mrnews/repo`, requires a signature trusted by
   `/etc/fleet-update/allowed_signers` and a fast-forward of
   `/var/lib/mrnews/deployed-rev`, `nix build`s the site, swaps the
   `/var/lib/mrnews/site` symlink (GC-rooted under `gcroots/`) and restarts
   `mrnews.service`. static-web-server resolves `--root` once at startup, so the
   restart is required. A 15-minute timer runs the same unit as a backstop.

## Why not the flake input

Until 2026-09-23 the site was the `mrnews` flake input, so a post only went
live when the nightly `rolling-flake-update` bumped the lock and doc1
redeployed. That job stopped completing on 2026-09-11 and five posts sat at
404 for up to 11 days; the jobs logged the 404 but delivered results only
locally. The flake input now only seeds `/var/lib/mrnews/site` on a fresh host
(tmpfiles `L`, never overwrites).

## Operations

- Deploy now: `mrnews-deploy` (as abl030, no sudo).
- Live revision: `cat /var/lib/mrnews/deployed-rev`.
- Logs: `journalctl -u mrnews-deploy -u mrnews`.
- Rolling back means pushing a signed revert to mrnews master; the deployer
  refuses non-fast-forward history.
