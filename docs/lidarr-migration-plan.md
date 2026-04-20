# Lidarr Stack Migration: doc2 -> downloader

**Goal**: Move Lidarr + slskd + cratedigger from doc2 (NixOS VM on Proxmox, NFS over network) to downloader (Ubuntu VM on Unraid, CIFS local to NAS) for dramatically better I/O performance.

**Temporary migration** — NixOS modules stay intact for future return.

## Current State

| Service | doc2 (192.168.1.35) | downloader (192.168.1.4) |
|---------|---------------------|--------------------------|
| Lidarr | NixOS native, port 8686, 15GB data dir | Not installed |
| slskd | NixOS native, port 5030/50300, VPN via ens19 | Not present |
| cratedigger | NixOS native, 5min timer, from abl030/cratedigger fork | Not present |
| Prowlarr | — | Already running, port 9696, already has Lidarr app connection |
| Deluge | — | Already running, port 8112/58846 |
| Music path | `/mnt/fuse/Media/Music/AI` (bindfs over NFS) | `/media/data/Media/Music/AI` (CIFS, local to NAS) |
| Download path | `/mnt/data/Media/Temp/slskd` (NFS) | `/media/data/Media/Temp/slskd` (CIFS, local to NAS) |
| VPN | Policy routing via ens19 | Router-level VPN (handled by pfSense) |
| Reverse proxy | nginx on doc2 (localProxy) | Caddy on cad (192.168.1.6) |

## Key Integration Points

```
Prowlarr (downloader:9696)  --syncs indexers-->  Lidarr (downloader:8686)
                                                    ^
                                                    |  pyarr API
                                                    v
cratedigger (cron/systemd)  --slskd-api-->  slskd (downloader:5030)
                                          |
                                          |  Soulseek P2P (VPN at router level)
                                          v
                                    /media/data/Media/Temp/slskd  (CIFS)
                                          |
                                          |  Lidarr import
                                          v
                                    /media/data/Media/Music/AI  (CIFS)
```

## Pre-requisites (User Action)

- [ ] **Step 0**: Shut down downloader VM, bump RAM from 2GB to 4GB, restart

## Migration Steps

### Phase 1: Stop services on doc2

```bash
# On doc2 — stop all three services
ssh doc2 "sudo systemctl stop cratedigger.timer cratedigger.service"
ssh doc2 "sudo systemctl stop slskd.service"
ssh doc2 "sudo systemctl stop lidarr.service"
```

Verify nothing is running:
```bash
ssh doc2 "systemctl status lidarr slskd cratedigger --no-pager"
```

### Phase 2: Install Lidarr on downloader

Following the same pattern as Sonarr/Radarr on this VM.

#### 2a. Create lidarr user and group
```bash
ssh downloader "sudo useradd -r -s /usr/sbin/nologin -d /var/lib/lidarr lidarr"
ssh downloader "sudo usermod -aG media lidarr"
ssh downloader "sudo usermod -aG users lidarr"  # for CIFS mount access
```

#### 2b. Download and install Lidarr
```bash
ssh downloader << 'INSTALL'
sudo bash -c '
  cd /tmp
  # Get latest Lidarr release (master branch, linux-x64)
  curl -sL "https://lidarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=x64" -o lidarr.tar.gz
  tar -xzf lidarr.tar.gz -C /opt/
  chown -R lidarr:media /opt/Lidarr
  rm lidarr.tar.gz
'
INSTALL
```

#### 2c. Create data directory and copy config from doc2
```bash
ssh downloader "sudo mkdir -p /var/lib/lidarr"
ssh downloader "sudo chown lidarr:media /var/lib/lidarr"

# Copy Lidarr database and config from doc2
# The data dir on doc2 is /mnt/virtio/lidarr (15GB — mostly MediaCover cache)
# Essential files: config.xml, lidarr.db, logs.db
ssh doc2 "sudo tar czf /tmp/lidarr-backup.tar.gz -C /mnt/virtio/lidarr config.xml lidarr.db logs.db"
scp doc2:/tmp/lidarr-backup.tar.gz /tmp/lidarr-backup.tar.gz
scp /tmp/lidarr-backup.tar.gz downloader:/tmp/lidarr-backup.tar.gz
ssh downloader "sudo tar xzf /tmp/lidarr-backup.tar.gz -C /var/lib/lidarr && sudo chown -R lidarr:media /var/lib/lidarr"
```

**NOTE**: We skip MediaCover (13GB of cached album art) — Lidarr will re-download as needed.

#### 2d. Update paths in Lidarr config
The config.xml needs the bind address set. The root folder path in the DB needs updating from `/mnt/fuse/Media/Music/AI` to `/media/data/Media/Music/AI`.

```bash
# Update config.xml — set bind to all interfaces, keep same API key
ssh downloader "sudo sed -i 's|<BindAddress>.*</BindAddress>|<BindAddress>*</BindAddress>|' /var/lib/lidarr/config.xml"
```

The root folder + artist paths will be updated via Lidarr API after startup (Phase 5).

#### 2e. Create systemd service
```bash
ssh downloader "sudo tee /etc/systemd/system/lidarr.service << 'EOF'
[Unit]
Description=Lidarr Daemon
After=network.target

[Service]
User=lidarr
Group=media
Type=simple
ExecStart=/opt/Lidarr/Lidarr -nobrowser -data=/var/lib/lidarr
TimeoutStopSec=20
KillMode=process
Restart=on-failure
UMask=0002

[Install]
WantedBy=multi-user.target
EOF"
```

#### 2f. Add CIFS backup mount (like Sonarr/Radarr have)
```bash
ssh downloader "sudo mkdir -p /var/lib/lidarr/Backups/remote"
ssh downloader "sudo chown lidarr:media /var/lib/lidarr/Backups/remote"
# Add to fstab
ssh downloader "echo '//192.168.1.2/data/Life/Tech/Backups/Lidarr   /var/lib/lidarr/Backups/remote  cifs credentials=/home/abl030/.smbcredentials,uid=abl030,gid=users,noperm 0 0' | sudo tee -a /etc/fstab"
```

Create the backup dir on the NAS if it doesn't exist:
```bash
ssh downloader "sudo mkdir -p /media/data/Life/Tech/Backups/Lidarr"
ssh downloader "sudo mount /var/lib/lidarr/Backups/remote"
```

#### 2g. Start Lidarr
```bash
ssh downloader "sudo systemctl daemon-reload && sudo systemctl enable --now lidarr.service"
ssh downloader "systemctl status lidarr --no-pager"
# Verify web UI responds
ssh downloader "curl -s http://localhost:8686/ping"
```

### Phase 3: Install slskd on downloader

#### 3a. Download slskd
```bash
ssh downloader << 'INSTALL'
sudo bash -c '
  cd /tmp
  # slskd 0.24.3 (match doc2 version)
  curl -sL "https://github.com/slskd/slskd/releases/download/0.24.3/slskd-0.24.3-linux-x64.zip" -o slskd.zip
  mkdir -p /opt/slskd
  unzip -o slskd.zip -d /opt/slskd/
  chmod +x /opt/slskd/slskd
  rm slskd.zip
'
INSTALL
```

#### 3b. Create slskd user and config
```bash
ssh downloader "sudo useradd -r -s /usr/sbin/nologin -d /var/lib/slskd slskd"
ssh downloader "sudo usermod -aG media slskd"
ssh downloader "sudo usermod -aG users slskd"
ssh downloader "sudo mkdir -p /var/lib/slskd"
ssh downloader "sudo chown slskd:media /var/lib/slskd"
```

Create slskd config (YAML) — needs Soulseek credentials from sops:
```bash
# We'll need to extract the sops secrets manually for this non-Nix host.
# Decrypt locally and push to downloader.
cd /home/abl030/nixosconfig
sops -d secrets/slskd.env > /tmp/slskd-secrets.env
source /tmp/slskd-secrets.env

ssh downloader "sudo tee /var/lib/slskd/slskd.yml << EOFCFG
web:
  port: 5030
  url_base: /
  authentication:
    disabled: true
soulseek:
  username: ${SLSKD_SLSK_USERNAME}
  password: ${SLSKD_SLSK_PASSWORD}
  listen_port: 50300
directories:
  downloads: /media/data/Media/Temp/slskd
  incomplete: /media/data/Media/Temp/slskd/incomplete
shares:
  directories:
    - /media/data/Media/Music/AI
global:
  upload:
    slots: 5
    speed_limit: 1000
flags:
  no_logo: true
EOFCFG"

ssh downloader "sudo chown slskd:media /var/lib/slskd/slskd.yml"
ssh downloader "sudo chmod 600 /var/lib/slskd/slskd.yml"

# Clean up local secrets
rm /tmp/slskd-secrets.env
```

#### 3c. Create slskd systemd service
```bash
ssh downloader "sudo tee /etc/systemd/system/slskd.service << 'EOF'
[Unit]
Description=slskd Soulseek Client
After=network.target

[Service]
User=slskd
Group=media
Type=simple
ExecStart=/opt/slskd/slskd --app-dir /var/lib/slskd --config /var/lib/slskd/slskd.yml
Restart=on-failure
UMask=0002
Environment=SLSKD_NO_AUTH=true

[Install]
WantedBy=multi-user.target
EOF"
```

#### 3d. Start slskd
```bash
ssh downloader "sudo systemctl daemon-reload && sudo systemctl enable --now slskd.service"
ssh downloader "curl -s http://localhost:5030/api/v0/server | head -c 200"
```

**VPN**: The downloader VM is routed through VPN at the router level (pfSense), so no per-service VPN config is needed. Soulseek traffic is automatically tunnelled.

### Phase 4: Install cratedigger on downloader

#### 4a. Install Python and dependencies
```bash
ssh downloader << 'INSTALL'
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv
sudo python3 -m venv /opt/cratedigger-venv
sudo /opt/cratedigger-venv/bin/pip install requests music-tag pyarr slskd-api configparser
# Clone the fork
sudo git clone https://github.com/abl030/cratedigger.git /opt/cratedigger
INSTALL
```

#### 4b. Create cratedigger config
```bash
# Decrypt cratedigger secrets
sops -d secrets/soularr.env > /tmp/cratedigger-secrets.env
source /tmp/cratedigger-secrets.env

ssh downloader "sudo mkdir -p /var/lib/cratedigger"

# Need slskd API key too
sops -d secrets/slskd.env > /tmp/slskd-secrets.env
source /tmp/slskd-secrets.env

ssh downloader "sudo tee /var/lib/cratedigger/config.ini << EOFCFG
[Lidarr]
api_key = ${CRATEDIGGER_LIDARR_API_KEY}
host_url = http://localhost:8686
monitor_new_artists = false
search_type = incrementing_page
search_limit = 10

[slskd]
api_key = ${SLSKD_API_KEY}
host_url = http://localhost:5030
download_dir = /media/data/Media/Temp/slskd

[Release Settings]
use_most_common_tracknum = true
allow_multi_disc = true
accepted_countries = Europe,UK & Ireland,Worldwide,[Worldwide],United States,Australia
accepted_formats = CD,Vinyl,Digital Media

[Search Settings]
search_timeout = 60000
maximum_peer_queue = 500000
minimum_peer_upload_speed = 0
allowed_filetypes = flac,mp3,ogg,m4a,wma,aac,opus,alac

[Logging]
log_level = INFO
EOFCFG"

ssh downloader "sudo chown -R root:root /var/lib/cratedigger"

rm /tmp/cratedigger-secrets.env /tmp/slskd-secrets.env
```

#### 4c. Create cratedigger systemd timer + service
```bash
ssh downloader "sudo tee /etc/systemd/system/cratedigger.service << 'EOF'
[Unit]
Description=Cratedigger — Soulseek downloader for Lidarr
After=lidarr.service slskd.service
Wants=lidarr.service slskd.service

[Service]
Type=oneshot
ExecStart=/opt/cratedigger-venv/bin/python /opt/cratedigger/cratedigger.py
WorkingDirectory=/opt/cratedigger
Environment=CRATEDIGGER_CONFIG=/var/lib/cratedigger/config.ini
TimeoutStartSec=1800
EOF"

ssh downloader "sudo tee /etc/systemd/system/cratedigger.timer << 'EOF'
[Unit]
Description=Run Cratedigger every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF"
```

#### 4d. Start cratedigger
```bash
ssh downloader "sudo systemctl daemon-reload && sudo systemctl enable --now cratedigger.timer"
```

### Phase 5: Update paths and integrations

#### 5a. Update Lidarr root folder + all artist paths
Once Lidarr is running on the downloader, update paths via API:

```bash
# Get API key from config
API_KEY=$(ssh downloader "sudo grep -oP '(?<=<ApiKey>)[^<]+' /var/lib/lidarr/config.xml")

# Update root folder
curl -s -X PUT "http://192.168.1.4:8686/api/v1/rootfolder/5" \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $API_KEY" \
  -d '{"id": 5, "path": "/media/data/Media/Music/AI"}'

# Bulk update all artist paths
ARTIST_IDS=$(curl -s "http://192.168.1.4:8686/api/v1/artist" \
  -H "X-Api-Key: $API_KEY" | jq '[.[].id]')

curl -s -X PUT "http://192.168.1.4:8686/api/v1/artist/editor" \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $API_KEY" \
  -d "{\"artistIds\": $ARTIST_IDS, \"rootFolderPath\": \"/media/data/Media/Music/AI\", \"moveFiles\": false}"
```

#### 5b. Update Prowlarr -> Lidarr connection
Prowlarr already has a Lidarr app connection pointing to `https://lidarr.ablz.au`. Update it to point to localhost since they're on the same machine now:

Via Prowlarr UI at `http://192.168.1.4:9696`:
- Settings -> Apps -> Lidarr
- Change Prowlarr Server URL to `http://localhost:9696`
- Change Lidarr Server URL to `http://localhost:8686`
- Update API key if needed (should be same)

Or via API:
```bash
PROWLARR_KEY=$(ssh downloader "sudo grep -oP '(?<=<ApiKey>)[^<]+' /var/lib/prowlarr/config.xml")
# List apps to find the Lidarr connection ID
curl -s "http://192.168.1.4:9696/api/v1/applications" -H "X-Api-Key: $PROWLARR_KEY" | jq '.[] | select(.name == "Lidarr")'
# Then update with the correct localhost URLs
```

#### 5c. Update Lidarr download client (Deluge)
Lidarr currently has Deluge configured at `deluge.ablz.au` (remote via nginx). Since Deluge runs on the downloader locally, update to localhost:

Via Lidarr API or UI:
- Download Client -> Deluge
- Host: `localhost` (or `127.0.0.1`)
- Port: `58846`
- SSL: No (local connection)
- Category: `lidarr`

#### 5d. Verify download dir
Ensure the download temp dir exists and is writable:
```bash
ssh downloader "sudo mkdir -p /media/data/Media/Temp/slskd/incomplete"
ssh downloader "sudo chown -R slskd:media /media/data/Media/Temp/slskd"
ssh downloader "sudo chmod 2775 /media/data/Media/Temp/slskd"
```

### Phase 6: Reverse proxy via Caddy on cad

Wildcard DNS `*.ablz.au` points to cad (192.168.1.6). Caddy on cad already proxies other arr services (Sonarr, Radarr, Prowlarr, Deluge) to the downloader. We add Lidarr and slskd entries.

#### 6a. Remove domains from doc2's nginx (localProxy)

Update `hosts/doc2/configuration.nix` — remove `lidarr.ablz.au` and `slskd.ablz.au` from `homelab.localProxy.hosts`. This is a NixOS config change that gets deployed on next rebuild.

#### 6b. Add Caddy entries on cad

```bash
ssh cad "sudo tee -a /etc/caddy/Caddyfile << 'EOF'

lidarr.ablz.au {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy 192.168.1.4:8686
}

slskd.ablz.au {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy 192.168.1.4:5030
}
EOF"

ssh cad "sudo systemctl reload caddy"
```

#### 6c. Verify domains resolve

```bash
curl -s -o /dev/null -w "%{http_code}" https://lidarr.ablz.au/ping
curl -s -o /dev/null -w "%{http_code}" https://slskd.ablz.au/api/v0/server
```

### Phase 7: Verification

```bash
# 1. Lidarr responds
curl -s http://192.168.1.4:8686/ping

# 2. slskd is connected to Soulseek
curl -s http://192.168.1.4:5030/api/v0/server | jq '.isConnected'

# 3. Cratedigger timer is active
ssh downloader "systemctl list-timers cratedigger.timer"

# 4. Prowlarr syncs indexers to Lidarr
# Check Lidarr Settings -> Indexers — should show synced indexers

# 5. Check Lidarr can see music library
curl -s "http://192.168.1.4:8686/api/v1/rootfolder" \
  -H "X-Api-Key: $API_KEY" | jq '.[].accessible'

# 6. Test a library scan
curl -s -X POST "http://192.168.1.4:8686/api/v1/command" \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $API_KEY" \
  -d '{"name": "RescanFolders"}'
```

### Phase 8: Disable on doc2 (don't remove from Nix config)

Disable services in `hosts/doc2/configuration.nix` so they stay off after rebuild but the modules remain in the codebase for rollback:

```nix
# In hosts/doc2/configuration.nix — disable but keep code
homelab.services.lidarr.enable = false;      # or just comment out enable = true
homelab.services.slskd.enable = false;
homelab.services.cratedigger.enable = false;
homelab.services.inotify-receiver.enable = false;
homelab.mounts.bindfsMusic.enable = false;
```

Then rebuild doc2:
```bash
# Commit and push the config change first
ssh doc2 "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh"
```

This cleanly stops and disables all services via NixOS rather than manually masking systemd units.

## Rollback Plan

To move back to doc2:

1. Stop services on downloader:
```bash
ssh downloader "sudo systemctl stop cratedigger.timer slskd lidarr"
```

2. Re-enable in `hosts/doc2/configuration.nix`:
```nix
homelab.services.lidarr.enable = true;
homelab.services.slskd.enable = true;
homelab.services.cratedigger.enable = true;
homelab.services.inotify-receiver.enable = true;
homelab.mounts.bindfsMusic.enable = true;
```

3. Rebuild doc2:
```bash
ssh doc2 "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh"
```

4. Update Lidarr paths back to `/mnt/fuse/Media/Music/AI` via API

5. Remove `lidarr.ablz.au` and `slskd.ablz.au` from cad's Caddyfile, reload Caddy

6. Re-add domains to doc2's `homelab.localProxy.hosts`, rebuild doc2

## Resolved Questions

1. **VPN for slskd**: Downloader is routed through VPN at router level (pfSense). No per-service VPN config needed.
2. **Reverse proxy**: Use Caddy on cad (192.168.1.6) — wildcard DNS `*.ablz.au` already points there. Add `lidarr.ablz.au` and `slskd.ablz.au` entries.
3. **Inotify receiver on doc2**: Disable via NixOS config (`enable = false`), leave all code in the repo for rollback.
4. **Cratedigger fork**: Clone `github:abl030/cratedigger` on downloader. Verify monitored-release patch works with pip-installed deps.
5. **Lidarr download clients**: Deluge on downloader uses categories for Sonarr/Radarr. Add a `lidarr` category.

## Files Changed

| File | Change |
|------|--------|
| `hosts/doc2/configuration.nix` | Disable lidarr, slskd, cratedigger, inotify-receiver, bindfsMusic (set `enable = false`) |
| `hosts/doc2/configuration.nix` | Remove lidarr.ablz.au and slskd.ablz.au from localProxy.hosts |
| `/etc/caddy/Caddyfile` on cad | Add lidarr.ablz.au and slskd.ablz.au reverse proxy entries |

All NixOS module code stays intact for rollback. The downloader setup is out-of-band on an unmanaged Ubuntu VM.
