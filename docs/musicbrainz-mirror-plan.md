# MusicBrainz Mirror + LRCLIB + Lidarr Nightly — Implementation Plan

Reference bead: `nixosconfig-jdw`
Guide: https://github.com/blampe/hearring-aid/blob/main/docs/self-hosted-mirror-setup.md

## Architecture Decision

musicbrainz-docker requires `podman compose build` for custom images (Solr with MB cores,
Postgres with pg_amqp). Build is fast (layer-cached), data lives in bind-mount volumes and
is completely unaffected by rebuilds. Rebuilding images every ~10 days on upstream releases
is fine — the build is a no-op when layers are cached.

**Chosen approach**: Flake input + `mkService` with `extraComposeFiles` extension.

- `musicbrainz-docker` added as `flake = false` input in `flake.nix`, floats on `master`
- Base compose: `${inputs.musicbrainz-docker}/docker-compose.yml` — in Nix store, read-only
  is fine, build contexts resolve relative to the compose file location
- Override files in `stacks/musicbrainz/overrides/`, passed via new `extraComposeFiles` param
- `stacks/lib/podman-compose.nix` tweaked to accept `extraComposeFiles ? []` — appends
  additional `-f` flags after the base `-f ${composeFile}` in all compose invocations
- Build step added via existing `preStart` list: `podman compose ... build`
- Uses standard `mkService` pattern — Home Manager user service, sops via `envFiles`,
  same as every other stack
- `--project-name musicbrainz` for predictable container names (needed by reindex timer)
- Volume bind mounts at `/mnt/docker/musicbrainz/volumes/` on doc1

## How Sops Works in Our Setup (for reference)

All stacks are **Home Manager user services** (`home-manager.users.${user}.systemd.user.services`).
`mkService` creates `sops.secrets` entries with `owner = user` — sops-nix decrypts as root
but the file is readable by the user. An `ExecStartPre` script (`resolveEnvPaths`) finds the
decrypted path and writes it to `${XDG_RUNTIME_DIR}/secrets/${stackName}.env-paths`. The main
compose script reads that file and passes `--env-file <path>` to podman compose. Compose talks
to the user's rootless podman socket via `CONTAINER_HOST=unix://${runUserDir}/podman/podman.sock`.
No special handling needed — just pass `envFiles` to `mkService` as normal.

## Current Status (2026-02-23)

### Completed
- ✅ Steps 0–9: disk expanded, flake inputs, podman-compose.nix, stack files, secrets, Lidarr nightly
- ✅ Step 11 (LRCLIB): Nix `dockerTools.buildLayeredImage` approach works; container running on :3300
- ✅ Step 7 (DB init): `createdb.sh -fetch` run, Solr reindexed (artist + release)
- ✅ Step 8 (weekly Solr reindex timer): in `docker-compose.nix`, runs Sun 01:00
- ✅ lm_cache_db: created + schema applied idempotently via `postStart` script
- ✅ Replication token: preStart extracts token from env file → bind-mount into container
- ✅ All API keys verified: Fanart.tv (18 images), Spotify (auth OK), Last.fm, TADB, LRCLIB lyrics
- ✅ Initial replication: complete (sequence 183955, last replicated 2026-02-22 12:00 UTC)
- ✅ Kuma monitors: LMD :5001, LRCLIB :3300 — all green
- ✅ Step 14: dbdump cleaned up (freed ~7GB)
- ✅ Step 12: Daily replication timer deployed (musicbrainz-replication.timer, fires 03:00 AWST)
- ✅ Step 10/15 Part A: LMD wired into Lidarr via `metadatasource` SQLite key
  - `Config` row: `metadatasource = http://192.168.1.29:5001/`
  - No plugin needed — Lidarr appends `/artist/{id}`, `/album/{id}`, `/search?...` to base URL
  - LMD verified serving all three endpoint shapes

### Remaining
- ⏳ Step 10/15 Part B: Tubifarry plugin install (UI-only, adds LRCLIB lyrics fetching)
  - System → Plugins → `https://github.com/TypNull/Tubifarry` → Install → Restart
  - Settings → Metadata → enable Lyrics Fetcher (create LRC files + embed)
  - Note: Tubifarry v2.0.x has no custom LRCLIB URL — it hits lrclib.net, not our local instance
  - Local LRCLIB remains available for other clients (Beets, players, etc.)
- ⏳ Step 13: Monthly LRCLIB dump refresh automation
  - BLOCKED on disk: ~23GB free, atomic swap needs ~97GB (78GB new db + 78GB old + 10GB zst)
  - Options: VM disk expansion (+100G via proxmox-ops.sh) or in-place overwrite (no atomic safety)

Next action: Tubifarry UI install (user-driven), then Step 13 disk planning.

## Files to Create/Edit

- [ ] `flake.nix` — add musicbrainz-docker input
- [ ] `stacks/lib/podman-compose.nix` — add `extraComposeFiles ? []` parameter
- [ ] `stacks/musicbrainz/docker-compose.nix` — mkService call
- [ ] `stacks/musicbrainz/overrides/postgres-settings.yml`
- [ ] `stacks/musicbrainz/overrides/memory-settings.yml`
- [ ] `stacks/musicbrainz/overrides/volume-settings.yml`
- [ ] `stacks/musicbrainz/overrides/lmd-settings.yml`
- [ ] `modules/nixos/homelab/containers/stacks.nix` — register musicbrainz stack
- [ ] `hosts.nix` — add "musicbrainz" to proxmox-vm containerStacks, update disk to 400G
- [ ] `secrets/musicbrainz.env` — sops encrypted (via `/sops-decrypt` skill)
- [ ] `stacks/music/docker-compose.yml` — switch lidarr:latest → lidarr:nightly (backup first)

## Step 0: Disk Expansion (prerequisite, do first)

doc1 currently: 250G disk, 53GB free. Needs ~120GB+ for MB+LRCLIB.

```bash
# Resize Proxmox disk (from local machine):
/home/abl030/nixosconfig/vms/proxmox-ops.sh resize 104 scsi0 +150G

# Grow partition + filesystem online on doc1 (ext4 on sda2):
ssh doc1
sudo growpart /dev/sda 2
sudo resize2fs /dev/sda2
df -h /  # verify — should show ~400G
```

Update `hosts.nix`: `disk = "400G";`

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

`inputs` is already passed through to all modules via `inherit inputs;` in `nix/lib.nix`
specialArgs — no other plumbing needed.

## Step 2: Extend podman-compose.nix

In `stacks/lib/podman-compose.nix`, add `extraComposeFiles ? []` to `mkService` args.
Everywhere the script builds compose flags, append `-f` for each extra file after the base:

```nix
mkService = {
  # ... existing args ...
  extraComposeFiles ? [],   # <-- new
  ...
}: let
  # Build a string of extra -f flags to append after the base composeFile
  extraComposeFlags = lib.concatMapStringsSep " " (f: "-f ${f}") extraComposeFiles;
  # ...
  # In composeWithSystemdLabelScript, change every occurrence of:
  #   ${podmanCompose} ${composeArgs} -f ${composeFile} ...
  # to:
  #   ${podmanCompose} ${composeArgs} -f ${composeFile} ${extraComposeFlags} ...
```

Occurrences to update in the script (lines ~262, 270, 273, 274, 277, 280):
- The `config --services` call (for label injection)
- The `up`, `update`, `reload`, `stop` cases

## Step 3: Override Files

`stacks/musicbrainz/overrides/` — tracked in nixosconfig.
Volume paths use `/mnt/docker/musicbrainz/volumes/`.

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

## Step 4: NixOS Module

`stacks/musicbrainz/docker-compose.nix` — registered in `stacks.nix` + `hosts.nix` like any
other stack. Uses `mkService` with the new `extraComposeFiles` param and a build `preStart`.

```nix
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  stackName = "musicbrainz-stack";
  projectName = "musicbrainz";

  # Base compose from flake input — build contexts resolve relative to this path
  baseCompose = "${inputs.musicbrainz-docker}/docker-compose.yml";

  # Override files from our repo
  mkOverride = name: builtins.path {
    path = ./overrides/${name};
    name = "musicbrainz-${name}";
  };
  postgresOverride = mkOverride "postgres-settings.yml";
  memoryOverride   = mkOverride "memory-settings.yml";
  volumeOverride   = mkOverride "volume-settings.yml";
  lmdOverride      = mkOverride "lmd-settings.yml";

  encEnv = config.homelab.secrets.sopsFile "musicbrainz.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};

  volumeBase = "/mnt/docker/musicbrainz/volumes";

  # Build step — runs before up on every start (fast no-op when layers cached)
  buildStep = let
    extraFlags = lib.concatStringsSep " " [
      "-f ${postgresOverride}"
      "-f ${memoryOverride}"
      "-f ${volumeOverride}"
      "-f ${lmdOverride}"
    ];
  in [
    "${pkgs.podman}/bin/podman compose --project-name ${projectName} -f ${baseCompose} ${extraFlags} build"
  ];
in {
  # Volume directories
  systemd.tmpfiles.rules = [
    "d ${volumeBase}/mqdata   0755 abl030 users -"
    "d ${volumeBase}/pgdata   0755 abl030 users -"
    "d ${volumeBase}/solrdata 0755 abl030 users -"
    "d ${volumeBase}/dbdump   0755 abl030 users -"
    "d ${volumeBase}/solrdump 0755 abl030 users -"
    "d ${volumeBase}/lmdconfig 0755 abl030 users -"
  ];

  imports = [
    (podman.mkService {
      inherit stackName;
      description = "MusicBrainz Mirror + LMD Stack";
      inherit projectName;
      composeFile = baseCompose;
      extraComposeFiles = [ postgresOverride memoryOverride volumeOverride lmdOverride ];
      composeArgs = "--project-name ${projectName}";
      envFiles = [{
        sopsFile = encEnv;
        runFile = "/run/user/%U/secrets/${stackName}.env";
      }];
      preStart = buildStep;
      firewallPorts = [ 5000 5001 ];
      startupTimeoutSeconds = 600;  # build can take a few minutes first time
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
    })
  ];
}
```

## Step 5: Register the Stack

In `stacks/lib/stacks.nix`, add:
```nix
musicbrainz = ../../../../stacks/musicbrainz/docker-compose.nix;
```

In `hosts.nix` proxmox-vm containerStacks, add `"musicbrainz"`.

## Step 6: Sops Secret

Create `secrets/musicbrainz.env` via `/sops-decrypt` skill:
```
FANART_KEY=
SPOTIFY_ID=
SPOTIFY_SECRET=
LASTFM_KEY=
LASTFM_SECRET=
```
MB replication token is set separately during manual init — not a runtime secret.

## Step 7: Manual Init (once, after first deploy)

Container names are predictable: `musicbrainz-musicbrainz-1`, `musicbrainz-indexer-1`, etc.
(project name `musicbrainz` + service name + instance number)

```bash
ssh doc1

# Start stack — triggers build then up:
systemctl --user start musicbrainz-stack

# Create DB (takes 1+ hour):
podman exec -it musicbrainz-musicbrainz-1 createdb.sh -fetch

# Index Solr (takes several hours):
podman exec -it musicbrainz-indexer-1 python -m sir reindex \
  --entity-type artist --entity-type release

# Set replication token (from metabrainz.org/profile → access tokens):
# The token goes into the container config — follow metabrainz docs:
# https://github.com/metabrainz/musicbrainz-docker#replication
podman exec -it musicbrainz-musicbrainz-1 bash
# Inside container: set REPLICATION_ACCESS_TOKEN and run replication.sh

# Run initial replication (use screen, takes hours):
screen
podman exec -it musicbrainz-musicbrainz-1 replication.sh
# Ctrl+A D to detach

# After replication completes:
systemctl --user stop musicbrainz-stack
rm -rf /mnt/docker/musicbrainz/volumes/dbdump/*  # free ~6GB
systemctl --user start musicbrainz-stack

# Init LMD cache DB (one-time):
podman exec -it musicbrainz-musicbrainz-1 bash -c "
  cd /tmp
  git clone https://github.com/Lidarr/LidarrAPI.Metadata.git
  psql postgres://abc:abc@db/musicbrainz_db -c 'CREATE DATABASE lm_cache_db;'
  psql postgres://abc:abc@db/musicbrainz_db \
    -f LidarrAPI.Metadata/lidarrmetadata/sql/CreateIndices.sql
"
systemctl --user restart musicbrainz-stack
```

### Validate:
```bash
curl http://192.168.1.29:5001/artist/1921c28c-ec61-4725-8e35-38dd656f7923 | jq .name
# → "I Prevail"
```

## Step 8: Weekly Solr Reindex Timer

Add to `stacks/musicbrainz/docker-compose.nix` alongside the mkService import:

```nix
home-manager.users.abl030.systemd.user = {
  services.musicbrainz-reindex = {
    Unit.Description = "MusicBrainz weekly Solr reindex";
    Service = {
      Type = "oneshot";
      Environment = [ "XDG_RUNTIME_DIR=/run/user/1000" "CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock" ];
      ExecStart = "${pkgs.podman}/bin/podman exec musicbrainz-indexer-1 \
        python -m sir reindex --entity-type artist --entity-type release";
    };
  };
  timers.musicbrainz-reindex = {
    Unit.Description = "MusicBrainz weekly Solr reindex timer";
    Timer = {
      OnCalendar = "Sun 01:00";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
};
```

## Step 9: Switch Lidarr to Nightly

**Backup first:**
```bash
ssh doc1
cp -r /mnt/docker/music/lidarr /mnt/docker/music/lidarr.bak-$(date +%Y%m%d)
```

In `stacks/music/docker-compose.yml`:
```yaml
image: lscr.io/linuxserver/lidarr:nightly  # was :latest
```

Deploy. One-way DB migration — Lidarr upgrades schema automatically on first start.

## Step 10: Tubifarry Plugin + Configure LMD

In Lidarr web UI (`https://lidarr.ablz.au`):
1. System → Plugins → Install: `https://github.com/TypNull/Tubifarry`
2. Restart Lidarr
3. System → Plugins → Install develop branch: `https://github.com/TypNull/Tubifarry/tree/develop`
4. Restart Lidarr
5. Settings → Metadata → Metadata Consumers → Lidarr Custom
6. Check both boxes, URL: `http://192.168.1.29:5001`
7. Save + restart

## Step 11: LRCLIB

**Status: BLOCKED** — `ghcr.io/tranxuanthang/lrclib:latest` returns 403 (not public). Building
from source inside the container fails because cargo downloads from `static.crates.io`
time out from Perth (30s timeout, ~3 retries per crate, dozens of crates = guaranteed fail).

**Chosen fix: Nix dockerTools build** — build lrclib with Nix, bypasses crates.io entirely.

### Implementation

In `stacks/musicbrainz/docker-compose.nix`:

```nix
lrclibPkg = pkgs.rustPlatform.buildRustPackage {
  pname = "lrclib";
  version = "0.1.0";
  src = inputs.lrclib-src;
  cargoLock.lockFile = "${inputs.lrclib-src}/Cargo.lock";
  buildInputs = [ pkgs.sqlite ];
  nativeBuildInputs = [ pkgs.pkg-config ];
};

lrclibImage = pkgs.dockerTools.buildLayeredImage {
  name = "lrclib-nix";
  tag = "latest";
  contents = [ lrclibPkg pkgs.cacert ];
  config = {
    Cmd = [ "${lrclibPkg}/bin/lrclib" "serve" "--port" "3300" ];
    ExposedPorts = { "3300/tcp" = {}; };
    Volumes = { "/data" = {}; };
  };
};
```

Add to `preStart` (before the compose build step):
```nix
"${pkgs.podman}/bin/podman load < ${lrclibImage}"
```

Change `lrclibBuildOverride` to use the pre-loaded image (no build context):
```nix
lrclibBuildOverride = pkgs.writeText "musicbrainz-lrclib-image.yml" ''
  services:
    lrclib:
      image: lrclib-nix:latest
'';
```

Remove lrclib from the compose `build` step (it's pre-loaded, not built by compose).

### Remaining lmd-settings.yml (already in place):
```yaml
  lrclib:
    container_name: musicbrainz-lrclib-1
    ports:
      - "3300:3300"
    volumes:
      - lrclib-data:/data
    restart: unless-stopped
```

Volume definition + tmpfiles rule + port 3300 + Kuma monitor already added.

Monthly dump refresh (~19GB): download from https://lrclib.net/db-dumps and replace the
SQLite file in the volume. No incremental updates exist — maintainer uploads full dumps
manually ~monthly.

Update tagging agent to use `http://192.168.1.29:3300` instead of `https://lrclib.net`.

## Step 12: Daily Replication Timer

MetaBrainz publishes hourly replication packets; running daily is sufficient for a personal
mirror. Same pattern as the existing `musicbrainz-reindex` timer already in `docker-compose.nix`.

Add to `home-manager.users.abl030.systemd.user` in `docker-compose.nix`:

```nix
services.musicbrainz-replication = {
  Unit.Description = "MusicBrainz daily replication";
  Service = {
    Type = "oneshot";
    Environment = [
      "XDG_RUNTIME_DIR=/run/user/1000"
      "CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock"
    ];
    ExecStart = "${pkgs.podman}/bin/podman exec musicbrainz-musicbrainz-1 replication.sh";
    TimeoutStartSec = "3600";  # replication can take a while if behind
  };
};
timers.musicbrainz-replication = {
  Unit.Description = "MusicBrainz daily replication timer";
  Timer = {
    OnCalendar = "*-*-* 03:00:00";  # 3am daily (AWST = 19:00 UTC prior day)
    Persistent = true;
  };
  Install.WantedBy = ["timers.target"];
};
```

No other changes needed — replication token is already wired via the preStart bind-mount.

## Step 13: Monthly LRCLIB Dump Refresh

LRCLIB has no incremental updates — the maintainer uploads full SQLite dumps ~monthly at
`https://lrclib.net/db-dumps`. The compressed dump is ~10–20GB; uncompressed ~78GB (SQLite).

**Strategy**: weekly check, download only if newer (ETag/Last-Modified), atomic swap,
restart lrclib container.

Add to `docker-compose.nix`:

```nix
lrclibUpdateScript = pkgs.writeShellScript "lrclib-db-update" ''
  set -euo pipefail

  DUMP_URL="https://lrclib.net/db-dumps/lrclib-db-dump-latest.db.zst"
  VOLUME_DIR="/mnt/docker/musicbrainz/volumes/lrclib"
  ETAG_FILE="$VOLUME_DIR/.dump-etag"
  TMP_DUMP="$VOLUME_DIR/db-dump.new.zst"
  NEW_DB="$VOLUME_DIR/db.sqlite3.new"

  # Check ETag — skip download if unchanged
  OLD_ETAG=$(cat "$ETAG_FILE" 2>/dev/null || echo "")
  NEW_ETAG=$(${pkgs.curl}/bin/curl -sI "$DUMP_URL" | grep -i '^etag:' | tr -d '\r' | awk '{print $2}')

  if [ "$OLD_ETAG" = "$NEW_ETAG" ] && [ -n "$NEW_ETAG" ]; then
    echo "LRCLIB dump unchanged (ETag: $NEW_ETAG), skipping"
    exit 0
  fi

  echo "New LRCLIB dump available (old: $OLD_ETAG, new: $NEW_ETAG), downloading..."
  ${pkgs.curl}/bin/curl -L --progress-bar -o "$TMP_DUMP" "$DUMP_URL"

  echo "Decompressing..."
  ${pkgs.zstd}/bin/zstd -d "$TMP_DUMP" -o "$NEW_DB" --force

  echo "Stopping lrclib container..."
  ${pkgs.podman}/bin/podman stop musicbrainz-lrclib-1 || true

  echo "Swapping database..."
  mv "$VOLUME_DIR/db.sqlite3" "$VOLUME_DIR/db.sqlite3.prev" || true
  mv "$NEW_DB" "$VOLUME_DIR/db.sqlite3"
  rm -f "$TMP_DUMP" "$VOLUME_DIR/db.sqlite3.prev"

  echo "$NEW_ETAG" > "$ETAG_FILE"

  echo "Starting lrclib container..."
  ${pkgs.podman}/bin/podman start musicbrainz-lrclib-1

  echo "LRCLIB database updated successfully"
'';
```

Add the timer:
```nix
services.lrclib-db-update = {
  Unit = {
    Description = "LRCLIB monthly database refresh";
    After = ["network-online.target"];
  };
  Service = {
    Type = "oneshot";
    Environment = [
      "XDG_RUNTIME_DIR=/run/user/1000"
      "CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock"
    ];
    ExecStart = "${lrclibUpdateScript}";
    TimeoutStartSec = "7200";  # download can take a while
  };
};
timers.lrclib-db-update = {
  Unit.Description = "LRCLIB monthly database refresh timer";
  Timer = {
    OnCalendar = "Sun *-*-01/7 04:00:00";  # weekly on Sundays, catches monthly releases
    Persistent = true;
  };
  Install.WantedBy = ["timers.target"];
};
```

**Note**: The update script uses `podman stop/start` directly rather than restarting the
whole stack, so the MB database and LMD stay up during the swap.

## Step 14: One-Time Cleanup After Initial Replication

Once `replication.sh` finishes its initial catch-up run (check with
`journalctl --user -u musicbrainz-stack -f` or `podman exec musicbrainz-musicbrainz-1 ps`):

```bash
# Free ~6GB of dump files no longer needed
rm -rf /mnt/docker/musicbrainz/volumes/dbdump/*

# Optionally restart to confirm clean state
systemctl --user restart musicbrainz-stack
```

## Step 15: Lidarr Plumbing (Tubifarry + LMD + LRCLIB)

Wire the running MB mirror into Lidarr so it uses local metadata instead of MusicBrainz.org
and TheAudioDB.

### Tubifarry Plugin (prerequisite for LMD)

1. In Lidarr web UI → **System → Plugins**
2. Install: `https://github.com/TypNull/Tubifarry` (main branch first)
3. Restart Lidarr
4. Install develop branch if needed: `https://github.com/TypNull/Tubifarry/tree/develop`
5. Restart Lidarr

### Configure LMD as Metadata Source

**Settings → Metadata → Metadata Consumers → Lidarr Custom:**
- Enable both checkboxes
- URL: `http://192.168.1.29:5001`
- Save + restart

This replaces TheAudioDB/Spotify calls with the local LMD instance, which itself falls
back to the live APIs only for cache misses.

### Configure LRCLIB as Lyrics Source

**Settings → Metadata → Lyrics → LRCLib:**
- URL override: `http://192.168.1.29:3300` (instead of `https://lrclib.net`)
- Save

Lidarr/Tubifarry will now query the local LRCLIB instance for lyrics.

### Verify

```bash
# Check LMD is serving metadata to Lidarr
curl -s "http://192.168.1.29:5001/artist/f59c5520-5f46-4d2c-b2c4-822eabf53419" | jq .artistName
# → "Radiohead"

# Check LRCLIB is serving lyrics locally
curl -s "http://192.168.1.29:3300/api/get?artist_name=Radiohead&track_name=Creep" | jq .syncedLyrics | head -3
```

### Add doc1 back to VPN Alias (if removed)

If doc1 was removed from `MV_VPN_IPS` pfSense alias for slskd (to avoid ban), add it back
after confirming slskd is working correctly from a VPN exit.

## API Keys Needed

| Service | Where to get |
|---------|-------------|
| Fanart.tv | fanart.tv → Profile → API Key (free) |
| Spotify | developer.spotify.com → Create app → Client ID + Secret |
| Last.fm | last.fm/api/account/create (free) |
| MusicBrainz replication | metabrainz.org/supporters → account-type → profile → access tokens |
