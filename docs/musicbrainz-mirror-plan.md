# MusicBrainz Mirror + LRCLIB + Lidarr Nightly — Implementation Plan

Reference bead: `nixosconfig-jdw`
Guide: https://github.com/blampe/hearring-aid/blob/main/docs/self-hosted-mirror-setup.md

## Architecture Decision

The musicbrainz-docker project uses `docker compose build` to produce custom images (Solr with MB
cores, custom Postgres with pg_amqp, etc.). This makes it **incompatible** with our standard
`podman.mkService` pattern, which only supports pre-built images.

**Chosen approach**: Semi-managed deployment.
- musicbrainz-docker lives at `/mnt/docker/musicbrainz-docker/` on doc1, cloned from upstream
- A minimal NixOS systemd unit wraps it (manages start/stop, firewall rules)
- LMD (`blampe/lidarr.metadata`) is added via a compose override file in the musicbrainz-docker
  local/compose/ directory — it IS part of the same compose project
- Sops secrets are injected via an env file that the override reads
- This is imported directly in `hosts/proxmox-vm/configuration.nix`, NOT via stackModules/stacks.nix

## Available Pre-built Images

Confirmed via skopeo:
- `metabrainz/musicbrainz-docker-db:16-build0` — postgres with pg_amqp
- `metabrainz/musicbrainz-docker-musicbrainz:v-2026-02-12.0-build1` — MB server (latest)
- `metabrainz/search-indexer:latest` — SIR indexer (old image, 2017 era — need to verify if still usable)
- `redis:3-alpine` — standard
- `rabbitmq:3-management` — standard (or whatever musicbrainz-docker build/rabbitmq uses)
- `blampe/lidarr.metadata:70a9707` — LMD

**Unknown**: Solr image. musicbrainz-docker builds a custom `mb-solr` image from `build/solr`.
No pre-built metabrainz Solr image found. **The build step cannot be avoided for Solr.**

Because of the Solr build requirement, the clone+build approach is mandatory.

## Step 0: Disk Expansion (prerequisite)

doc1 currently: 250G disk, 53GB free. Needs ~120GB+ for MB+LRCLIB.

```bash
# On local machine (proxmox-ops resize):
/home/abl030/nixosconfig/vms/proxmox-ops.sh resize 104 scsi0 +150G

# Then on doc1 — grow partition online (NixOS uses ext4 on sda2):
sudo growpart /dev/sda 2
sudo resize2fs /dev/sda2
df -h /  # verify
```

Update hosts.nix: `disk = "400G";` for proxmox-vm.

## Step 1: Clone musicbrainz-docker on doc1

```bash
ssh doc1
sudo mkdir -p /mnt/docker/musicbrainz-docker
sudo chown abl030:users /mnt/docker/musicbrainz-docker
cd /mnt/docker/musicbrainz-docker
git clone https://github.com/metabrainz/musicbrainz-docker.git .
mkdir -p local/compose volumes/{mqdata,pgdata,solrdata,dbdump,solrdump,lmdconfig}
```

## Step 2: Create Compose Override Files

These files live in musicbrainz-docker and are NOT tracked in nixosconfig.
They reference secrets injected at runtime via the NixOS systemd unit.

### `local/compose/postgres-settings.yml`
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

### `local/compose/memory-settings.yml`
```yaml
services:
  db:
    command: postgres -c "shared_buffers=2GB" -c "shared_preload_libraries=pg_amqp.so"
  search:
    environment:
      - SOLR_HEAP=2g
```

### `local/compose/volume-settings.yml`
```yaml
volumes:
  mqdata:
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz-docker/volumes/mqdata
      o: bind
  pgdata:
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz-docker/volumes/pgdata
      o: bind
  solrdata:
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz-docker/volumes/solrdata
      o: bind
  dbdump:
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz-docker/volumes/dbdump
      o: bind
  solrdump:
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz-docker/volumes/solrdump
      o: bind
  lmdconfig:
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz-docker/volumes/lmdconfig
      o: bind
    driver: local
```

### `local/compose/lmd-settings.yml`
```yaml
volumes:
  lmdconfig:
    driver_opts:
      type: none
      device: /mnt/docker/musicbrainz-docker/volumes/lmdconfig
      o: bind
    driver: local

services:
  lmd:
    image: blampe/lidarr.metadata:70a9707
    ports:
      - 5001:5001
    environment:
      DEBUG: false
      PRODUCTION: false
      USE_CACHE: true
      ENABLE_STATS: false
      ROOT_PATH: ""
      IMAGE_CACHE_HOST: "theaudiodb.com"
      EXTERNAL_TIMEOUT: 1000
      INVALIDATE_APIKEY: ""
      REDIS_HOST: "redis"
      REDIS_PORT: 6379
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

Register overrides:
```bash
admin/configure add \
  local/compose/postgres-settings.yml \
  local/compose/memory-settings.yml \
  local/compose/volume-settings.yml \
  local/compose/lmd-settings.yml
```

## Step 3: NixOS Module

Create `stacks/musicbrainz/service.nix` — NOT using podman.mkService, imported directly.

```nix
# stacks/musicbrainz/service.nix
# Wraps musicbrainz-docker at /mnt/docker/musicbrainz-docker/
# Not in stackModules — imported directly from hosts/proxmox-vm/configuration.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  mbDir = "/mnt/docker/musicbrainz-docker";
  encEnv = config.homelab.secrets.sopsFile "musicbrainz.env";
  runEnv = "/run/secrets/musicbrainz.env";
in {
  sops.secrets."musicbrainz.env" = {
    sopsFile = encEnv;
    owner = config.users.users.abl030.name;
    path = runEnv;
  };

  # Open ports for MB web UI and LMD
  networking.firewall.allowedTCPPorts = [ 5000 5001 ];

  systemd.user.services.musicbrainz-stack = {
    description = "MusicBrainz Docker Stack";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = runEnv;
      ExecStart = "${pkgs.podman}/bin/podman compose --project-directory ${mbDir} up -d";
      ExecStop = "${pkgs.podman}/bin/podman compose --project-directory ${mbDir} down";
    };
    wantedBy = [ "default.target" ];
  };
}
```

Add to `hosts/proxmox-vm/configuration.nix`:
```nix
imports = [
  ...
  ../../stacks/musicbrainz/service.nix
];
```

## Step 4: Sops Secret

Add `secrets/musicbrainz.env` to the repo. Use `/sops-decrypt` skill to create it with:
```
FANART_KEY=<get from fanart.tv account>
SPOTIFY_ID=<get from Spotify developer dashboard>
SPOTIFY_SECRET=<get from Spotify developer dashboard>
LASTFM_KEY=<get from Last.fm API account>
LASTFM_SECRET=<get from Last.fm API account>
MB_REPLICATION_TOKEN=<get from metabrainz.org/profile>
```

NOTE: MB_REPLICATION_TOKEN is used by the `admin/set-replication-token` script, not via the env
file. Set it separately during the manual init.

## Step 5: Build and Initialize (manual, user does this)

```bash
# Build images (required for Solr custom cores):
cd /mnt/docker/musicbrainz-docker
podman compose build

# Create DB (takes 1+ hour):
podman compose run --rm musicbrainz createdb.sh -fetch

# Start everything:
podman compose up -d

# Index Solr (takes several hours):
podman compose exec indexer python -m sir reindex \
  --entity-type artist --entity-type release

# Set up replication token:
podman compose down
admin/set-replication-token   # enter token from metabrainz.org
admin/configure add replication-token
podman compose up -d
podman compose exec musicbrainz replication.sh  # run in screen

# After replication finishes:
podman compose down
rm -rf volumes/dbdump/*   # free ~6GB
podman compose up -d

# Init LMD cache DB:
podman compose exec musicbrainz bash -c "
  cd /tmp
  git clone https://github.com/Lidarr/LidarrAPI.Metadata.git
  psql postgres://abc:abc@db/musicbrainz_db -c 'CREATE DATABASE lm_cache_db;'
  psql postgres://abc:abc@db/musicbrainz_db \
    -f LidarrAPI.Metadata/lidarrmetadata/sql/CreateIndices.sql
"
podman compose restart
```

### Validate:
```bash
curl http://192.168.1.29:5001/artist/1921c28c-ec61-4725-8e35-38dd656f7923 | jq .name
# Should return "I Prevail"
curl http://192.168.1.29:5000/artist/1921c28c-ec61-4725-8e35-38dd656f7923
# Should return MB web page for I Prevail
```

## Step 6: Weekly Solr Reindex Cron

Add to NixOS cron or as a systemd timer on doc1:
```
0 1 * * 7 abl030 cd /mnt/docker/musicbrainz-docker && \
  podman compose exec -T indexer python -m sir reindex \
  --entity-type artist --entity-type release
```

## Step 7: Switch Lidarr to Nightly

In `stacks/music/docker-compose.yml`, change:
```yaml
# FROM:
image: lscr.io/linuxserver/lidarr:latest
# TO:
image: lscr.io/linuxserver/lidarr:nightly
```

**IMPORTANT**: One-way DB migration. Take backup first:
```bash
ssh doc1
cp -r /mnt/docker/music/lidarr /mnt/docker/music/lidarr.bak-$(date +%Y%m%d)
```

Then restart the music-stack service to pull nightly.

## Step 8: Install Tubifarry and Configure LMD

In Lidarr web UI (`https://lidarr.ablz.au`):
1. System > Plugins > Install: `https://github.com/TypNull/Tubifarry`
2. Restart Lidarr
3. System > Plugins > Install develop branch: `https://github.com/TypNull/Tubifarry/tree/develop`
4. Restart Lidarr
5. Settings > Metadata > Metadata Consumers > Lidarr Custom
6. Check both boxes, set URL: `http://192.168.1.29:5001`
7. Save + restart

## Step 9: LRCLIB (separate, simpler)

Create a small additional service on doc1. Can be a simple podman run in a separate systemd unit
or added to the musicbrainz-docker compose as another override.

```bash
# Simple one-off approach:
podman run -d \
  --name lrclib \
  -v lrclib-data:/data \
  -p 3300:3300 \
  --restart unless-stopped \
  ghcr.io/tranxuanthang/lrclib:latest
```

Monthly cron to refresh dump (adds ~19GB data):
```bash
# Check https://lrclib.net/db-dumps for latest dump URL
# Download, replace SQLite db in volume
```

Expose port 3300 in NixOS firewall.
Update tagging agent to use `http://192.168.1.29:3300` instead of `https://lrclib.net`.

## Step 10: Update hosts.nix

```nix
proxmox.disk = "400G";  # was 250G
```

## API Keys Needed (get these before starting)

| Service | Where to get | Notes |
|---------|-------------|-------|
| Fanart.tv | fanart.tv/profile | Free, requires account |
| Spotify | developer.spotify.com | Create app, get Client ID + Secret |
| Last.fm | last.fm/api/account/create | Free |
| MusicBrainz replication | metabrainz.org/supporters/account-type | Required, free non-commercial |

## Open Questions / TODOs for Next Session

- [ ] Confirm `metabrainz/search-indexer:latest` is still usable with SolrCloud 9 musicbrainz-docker
      (it's from 2017 era — may be the indexer running inside musicbrainz-docker not this image)
- [ ] Check if the NixOS module approach for systemd.user.services works with sops secret access
      (sops secrets at /run/secrets/ may not be accessible by user services by default)
- [ ] Consider whether to use system-level podman instead of rootless for musicbrainz-docker
      (since rootless complicates bind mounts and sops secret access)
- [ ] LRCLIB image: confirm `ghcr.io/tranxuanthang/lrclib:latest` is the right registry
- [ ] Verify `podman compose --project-directory` works the same as `cd && podman compose`

## Files to Create/Edit in nixosconfig

- [ ] `stacks/musicbrainz/service.nix` — NixOS module
- [ ] `secrets/musicbrainz.env` — sops encrypted (via /sops-decrypt skill)
- [ ] `hosts/proxmox-vm/configuration.nix` — add import of service.nix
- [ ] `hosts.nix` — update disk to 400G
- [ ] `stacks/music/docker-compose.yml` — switch lidarr:latest → lidarr:nightly (with backup first)
