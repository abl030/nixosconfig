# MusicBrainz Mirror + LRCLIB + Lidarr Nightly — Implementation Plan

Reference bead: `nixosconfig-jdw`
Guide: https://github.com/blampe/hearring-aid/blob/main/docs/self-hosted-mirror-setup.md

## Architecture Decision

musicbrainz-docker requires `podman compose build` for custom images (Solr with MB cores,
Postgres with pg_amqp). Build is fast (layer-cached), data lives in bind-mount volumes and
is completely unaffected by rebuilds. Rebuilding images every ~10 days when upstream releases
is acceptable.

**Chosen approach**: Flake input + multi-file compose.

- `musicbrainz-docker` added as `flake = false` input in `flake.nix`, floats on `master`
- Base compose comes from `${inputs.musicbrainz-docker}/docker-compose.yml`
- Build contexts (`build: build/solr` etc.) resolve relative to the compose file in the Nix
  store — read-only is fine, they just read Dockerfiles
- Override files (postgres, memory, volumes, lmd) live in `stacks/musicbrainz/overrides/`
  tracked in nixosconfig, passed as `builtins.path`
- Custom systemd unit (not mkService — needs ExecStartPre build + multi-file -f flags)
- Sops secret `musicbrainz.env` for API keys
- Volume bind mounts at `/mnt/docker/musicbrainz/volumes/` on doc1

## Files to Create/Edit

- [ ] `flake.nix` — add musicbrainz-docker input
- [ ] `stacks/musicbrainz/docker-compose.nix` — NixOS module with systemd unit
- [ ] `stacks/musicbrainz/overrides/postgres-settings.yml`
- [ ] `stacks/musicbrainz/overrides/memory-settings.yml`
- [ ] `stacks/musicbrainz/overrides/volume-settings.yml`
- [ ] `stacks/musicbrainz/overrides/lmd-settings.yml`
- [ ] `secrets/musicbrainz.env` — sops encrypted (via `/sops-decrypt` skill)
- [ ] `hosts/proxmox-vm/configuration.nix` — import stacks/musicbrainz/docker-compose.nix
- [ ] `hosts.nix` — update proxmox-vm disk to 400G
- [ ] `stacks/music/docker-compose.yml` — switch lidarr:latest → lidarr:nightly (backup first)

## Step 0: Disk Expansion (prerequisite, do first)

doc1 currently: 250G disk, 53GB free. Needs ~120GB+ for MB+LRCLIB.

```bash
# Resize Proxmox disk (from local machine):
/home/abl030/nixosconfig/vms/proxmox-ops.sh resize 104 scsi0 +150G

# Grow partition + filesystem online on doc1 (NixOS uses ext4 on sda2):
ssh doc1
sudo growpart /dev/sda 2
sudo resize2fs /dev/sda2
df -h /  # verify — should show ~400G
```

Then update `hosts.nix`: `disk = "400G";`

## Step 1: flake.nix — Add Input

```nix
inputs = {
  # ... existing inputs ...
  musicbrainz-docker = {
    url = "github:metabrainz/musicbrainz-docker";
    flake = false;
  };
};
```

Pass it through in `nix/lib.nix` specialArgs so modules can access `inputs.musicbrainz-docker`.
(Already done for all inputs via `inherit inputs;` in specialArgs — check lib.nix to confirm.)

## Step 2: Override Files

These live in `stacks/musicbrainz/overrides/` in our repo.
Volume paths use `/mnt/docker/musicbrainz/` (not `/opt/docker/musicbrainz-docker/` from guide).

### `overrides/postgres-settings.yml`
```yaml
services:
  musicbrainz:
    environment:
      POSTGRES_USER: "abc"
      POSTGRES_PASSWORD: "abc"
      MUSICBRAINZ_WEB_SERVER_HOST: "192.168.1.29"
  db:
    environment:
      POSTGRES_USER: "abc"
      POSTGRES_PASSWORD: "abc"
  indexer:
    environment:
      POSTGRES_USER: "abc"
      POSTGRES_PASSWORD: "abc"
```

### `overrides/memory-settings.yml`
```yaml
services:
  db:
    command: postgres -c "shared_buffers=2GB" -c "shared_preload_libraries=pg_amqp.so"
  search:
    environment:
      - SOLR_HEAP=2g
```

### `overrides/volume-settings.yml`
```yaml
volumes:
  mqdata:
    driver: local
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz/volumes/mqdata
      o: bind
  pgdata:
    driver: local
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz/volumes/pgdata
      o: bind
  solrdata:
    driver: local
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz/volumes/solrdata
      o: bind
  dbdump:
    driver: local
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz/volumes/dbdump
      o: bind
  solrdump:
    driver: local
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz/volumes/solrdump
      o: bind
```

### `overrides/lmd-settings.yml`
```yaml
volumes:
  lmdconfig:
    driver: local
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz/volumes/lmdconfig
      o: bind

services:
  lmd:
    image: blampe/lidarr.metadata:70a9707
    ports:
      - "5001:5001"
    environment:
      DEBUG: "false"
      PRODUCTION: "false"
      USE_CACHE: "true"
      ENABLE_STATS: "false"
      ROOT_PATH: ""
      IMAGE_CACHE_HOST: "theaudiodb.com"
      EXTERNAL_TIMEOUT: "1000"
      INVALIDATE_APIKEY: ""
      REDIS_HOST: "redis"
      REDIS_PORT: "6379"
      FANART_KEY: "${FANART_KEY}"
      PROVIDERS__FANARTTVPROVIDER__0__0: "${FANART_KEY}"
      SPOTIFY_ID: "${SPOTIFY_ID}"
      SPOTIFY_SECRET: "${SPOTIFY_SECRET}"
      SPOTIFY_REDIRECT_URL: "http://192.168.1.29:5001"
      PROVIDERS__SPOTIFYPROVIDER__1__CLIENT_ID: "${SPOTIFY_ID}"
      PROVIDERS__SPOTIFYPROVIDER__1__CLIENT_SECRET: "${SPOTIFY_SECRET}"
      PROVIDERS__SPOTIFYAUTHPROVIDER__1__CLIENT_ID: "${SPOTIFY_ID}"
      PROVIDERS__SPOTIFYAUTHPROVIDER__1__CLIENT_SECRET: "${SPOTIFY_SECRET}"
      PROVIDERS__SPOTIFYAUTHPROVIDER__1__REDIRECT_URI: "http://192.168.1.29:5001"
      TADB_KEY: "2"
      PROVIDERS__THEAUDIODBPROVIDER__0__0: "2"
      LASTFM_KEY: "${LASTFM_KEY}"
      LASTFM_SECRET: "${LASTFM_SECRET}"
      PROVIDERS__SOLRSEARCHPROVIDER__1__SEARCH_SERVER: "http://search:8983/solr"
    restart: unless-stopped
    volumes:
      - lmdconfig:/config
    depends_on:
      - db
      - mq
      - search
      - redis
```

## Step 3: NixOS Module

`stacks/musicbrainz/docker-compose.nix` — imported directly from
`hosts/proxmox-vm/configuration.nix`, NOT via stackModules (non-standard build step).

```nix
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  mbSrc = inputs.musicbrainz-docker;
  overridesDir = builtins.path {
    path = ./overrides;
    name = "musicbrainz-overrides";
  };
  volumeBase = "/mnt/docker/musicbrainz/volumes";
  encEnv = config.homelab.secrets.sopsFile "musicbrainz.env";
  runEnv = "/run/user/%U/secrets/musicbrainz-stack.env";  # or system-level

  composeFlags = lib.concatStringsSep " " [
    "-f ${mbSrc}/docker-compose.yml"
    "-f ${overridesDir}/postgres-settings.yml"
    "-f ${overridesDir}/memory-settings.yml"
    "-f ${overridesDir}/volume-settings.yml"
    "-f ${overridesDir}/lmd-settings.yml"
  ];

  podman = "${pkgs.podman}/bin/podman";
in {
  sops.secrets."musicbrainz.env" = {
    sopsFile = encEnv;
    # Set owner/path appropriately
  };

  # Volume directories — must exist before service starts
  systemd.tmpfiles.rules = [
    "d ${volumeBase}/mqdata  0755 abl030 users -"
    "d ${volumeBase}/pgdata  0755 abl030 users -"
    "d ${volumeBase}/solrdata 0755 abl030 users -"
    "d ${volumeBase}/dbdump  0755 abl030 users -"
    "d ${volumeBase}/solrdump 0755 abl030 users -"
    "d ${volumeBase}/lmdconfig 0755 abl030 users -"
  ];

  networking.firewall.allowedTCPPorts = [ 5000 5001 ];

  # NOTE: decide system vs. user service — see open questions below
  systemd.user.services.musicbrainz-stack = {
    description = "MusicBrainz + LMD Stack";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = runEnv;
      ExecStartPre = "${podman} compose ${composeFlags} build --pull";
      ExecStart    = "${podman} compose ${composeFlags} up -d --remove-orphans";
      ExecStop     = "${podman} compose ${composeFlags} down";
      TimeoutStartSec = "600";  # build can take a few minutes
    };
    wantedBy = [ "default.target" ];
  };
}
```

## Step 4: Sops Secret

Create `secrets/musicbrainz.env` via `/sops-decrypt` skill with:
```
FANART_KEY=
SPOTIFY_ID=
SPOTIFY_SECRET=
LASTFM_KEY=
LASTFM_SECRET=
```
(MB replication token is set separately via the manual init process — not needed at runtime.)

## Step 5: Manual Init (do once after first deploy)

```bash
ssh doc1

# Build images first (also happens in ExecStartPre but do it explicitly first time):
# Find the Nix store path for mbSrc — or just use the systemd service:
systemctl --user start musicbrainz-stack  # triggers build + up

# Create DB (takes 1+ hour):
# Need to identify the musicbrainz container name:
podman ps | grep musicbrainz
podman exec -it <musicbrainz-container> createdb.sh -fetch

# Index Solr (takes several hours):
podman exec -it <indexer-container> python -m sir reindex \
  --entity-type artist --entity-type release

# Set replication token (from metabrainz.org/profile):
podman exec -it <musicbrainz-container> bash
# follow metabrainz docs for setting REPLICATION_ACCESS_TOKEN

# Run initial replication (use screen):
screen
podman exec -it <musicbrainz-container> replication.sh

# After replication completes:
systemctl --user stop musicbrainz-stack
rm -rf /mnt/docker/musicbrainz/volumes/dbdump/*  # free ~6GB
systemctl --user start musicbrainz-stack

# Init LMD cache DB:
podman exec -it <musicbrainz-container> bash -c "
  cd /tmp
  git clone https://github.com/Lidarr/LidarrAPI.Metadata.git
  psql postgres://abc:abc@db/musicbrainz_db -c 'CREATE DATABASE lm_cache_db;'
  psql postgres://abc:abc@db/musicbrainz_db \
    -f LidarrAPI.Metadata/lidarrmetadata/sql/CreateIndices.sql
"
podman exec musicbrainz-stack_lmd_1 restart  # or restart whole stack
```

### Validate:
```bash
curl http://192.168.1.29:5001/artist/1921c28c-ec61-4725-8e35-38dd656f7923 | jq .name
# → "I Prevail"
```

## Step 6: Weekly Solr Reindex (add to NixOS)

Add a systemd timer in the module:
```nix
systemd.user.services.musicbrainz-reindex = {
  description = "MusicBrainz weekly Solr reindex";
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${podman} exec musicbrainz-docker_indexer_1 \
      python -m sir reindex --entity-type artist --entity-type release";
  };
};
systemd.user.timers.musicbrainz-reindex = {
  timerConfig = {
    OnCalendar = "Sun 01:00";
    Persistent = true;
  };
  wantedBy = [ "timers.target" ];
};
```

## Step 7: Switch Lidarr to Nightly

**Backup first:**
```bash
ssh doc1
cp -r /mnt/docker/music/lidarr /mnt/docker/music/lidarr.bak-$(date +%Y%m%d)
```

In `stacks/music/docker-compose.yml`:
```yaml
# FROM:
image: lscr.io/linuxserver/lidarr:latest
# TO:
image: lscr.io/linuxserver/lidarr:nightly
```

Restart music-stack. One-way migration — DB schema upgrades automatically.

## Step 8: Tubifarry Plugin + Configure LMD

In Lidarr web UI (`https://lidarr.ablz.au`):
1. System → Plugins → Install: `https://github.com/TypNull/Tubifarry`
2. Restart
3. System → Plugins → Install develop branch: `https://github.com/TypNull/Tubifarry/tree/develop`
4. Restart
5. Settings → Metadata → Metadata Consumers → Lidarr Custom
6. Check both boxes, URL: `http://192.168.1.29:5001`
7. Save + restart

## Step 9: LRCLIB

Simplest — add as another service in `overrides/lmd-settings.yml` (rename to
`overrides/extras-settings.yml`), or a standalone podman run wrapped in its own
tiny systemd unit.

```bash
# Quick standalone approach:
podman run -d \
  --name lrclib \
  -v lrclib-data:/data \
  -p 3300:3300 \
  --restart unless-stopped \
  ghcr.io/tranxuanthang/lrclib:latest
```

Monthly cron to refresh dump (~19GB, maintainer uploads manually ~monthly):
```bash
# Download latest from https://lrclib.net/db-dumps and replace volume
```

Open port 3300 in NixOS firewall. Update tagging agent config to use
`http://192.168.1.29:3300`.

## Open Questions (resolve before implementing module)

1. **System vs user service**: User services can't easily access sops secrets at `/run/secrets/`
   (sops-nix puts them there as root). Options:
   - Use system-level `systemd.services` with `User = "abl030"` — sops secrets accessible
   - Or use `homelab.secrets.sopsFile` pattern used by other stacks (check how music-stack does it)
   - Check: does music-stack use system or user services? → it uses user services with
     `/run/user/%U/secrets/` path via sops `owner` setting

2. **Container names**: With multi-file `-f` compose, the project name determines container names.
   Default project name comes from `--project-directory` or the first compose file's directory
   name. May need `--project-name musicbrainz` to get predictable names for the exec commands
   in the reindex timer.

3. **`--pull` flag on build**: `podman compose build --pull` forces re-pulling base images on
   each start. Probably want this so we get upstream image updates, but adds latency. Consider
   only pulling on explicit updates vs. every start.

## API Keys Needed

| Service | Where to get |
|---------|-------------|
| Fanart.tv | fanart.tv → Profile → API Key (free) |
| Spotify | developer.spotify.com → Create app → Client ID + Secret |
| Last.fm | last.fm/api/account/create (free) |
| MusicBrainz replication | metabrainz.org/supporters → account-type → profile → token |
