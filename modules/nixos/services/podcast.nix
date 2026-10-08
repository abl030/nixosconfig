# modules/nixos/services/podcast.nix
{
  pkgs,
  lib,
  ...
}: let
  # CHANGED: Moved to NFS Mount
  podcastDir = "/mnt/data/Media/Podcasts";

  domain = "podcast.ablz.au";
  staticPort = 9010;
  podcastMimeTypes = pkgs.writeText "podcast-mime.types" ''
    application/rss+xml xml
    audio/mpeg mp3
    audio/mp4 m4a
    text/plain description txt
    image/jpeg jpg jpeg
    image/png png
    image/webp webp
  '';
  gotifyUrl = "https://gotify.ablz.au/message";
  gotifyToken = "AwE0qWRpsCU9tPk";

  # 1. Python Script (Generic RSS Generator)
  genRss =
    pkgs.writers.writePython3Bin "gen-rss" {
      libraries = [pkgs.python3Packages.mutagen];
      flakeIgnore = ["E501"];
    } ''
      import os
      import glob
      import argparse
      from email.utils import formatdate
      from mutagen.mp3 import MP3
      import html

      parser = argparse.ArgumentParser()
      parser.add_argument("--dir", required=True, help="Directory containing mp3s")
      parser.add_argument("--out", required=True, help="Output XML file path")
      parser.add_argument("--url", required=True, help="Base URL for enclosures")
      parser.add_argument("--title", default="My YouTube Drops", help="Feed Title")
      args = parser.parse_args()

      header = f"""<?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
      <title>{html.escape(args.title)}</title>
      <description>Generated Podcast Feed</description>
      <language>en-us</language>
      <link>{args.url}</link>
      """

      items = ""
      files = glob.glob(os.path.join(args.dir, "*.mp3"))
      files.sort(key=os.path.getmtime, reverse=True)

      for f in files:
          filename = os.path.basename(f)
          # Verify permissions (Best effort on NFS)
          try:
              os.chmod(f, 0o644)
          except Exception:
              pass

          clean_base = args.url.rstrip("/")
          url = f"{clean_base}/{filename}"

          stat = os.stat(f)
          size = stat.st_size
          pubDate = formatdate(stat.st_mtime)

          duration = "0"
          title = filename
          description = ""

          try:
              audio = MP3(f)
              duration = str(int(audio.info.length))
              if 'TIT2' in audio:
                  title = audio['TIT2'].text[0]
          except Exception:
              pass

          base_path = os.path.splitext(f)[0]
          desc_path = base_path + ".description"
          if os.path.exists(desc_path):
              try:
                  with open(desc_path, "r", encoding="utf-8") as df:
                      description = df.read()
              except Exception:
                  pass

          if not description:
              try:
                  audio = MP3(f)
                  comm_frames = [audio[k] for k in audio.keys() if k.startswith("COMM")]
                  if comm_frames:
                      comm_frames.sort(key=lambda x: len(x.text[0]) if x.text else 0, reverse=True)
                      if comm_frames[0].text:
                          description = comm_frames[0].text[0]
              except Exception:
                  pass

          items += f"""
          <item>
              <title>{html.escape(title)}</title>
              <description>{html.escape(description)}</description>
              <enclosure url="{url}" length="{size}" type="audio/mpeg"/>
              <guid>{url}</guid>
              <pubDate>{pubDate}</pubDate>
              <itunes:duration>{duration}</itunes:duration>
          </item>
          """

      footer = "</channel></rss>"

      with open(args.out, "w") as f:
          f.write(header + items + footer)

      try:
          os.chmod(args.out, 0o644)
      except Exception:
          pass
    '';

  # 2. Main Downloader
  downloader = pkgs.writeShellScriptBin "podcast-downloader" ''
    exec 1> >(${pkgs.util-linux}/bin/logger -t podcast-dl) 2>&1
    export PATH=$PATH:${pkgs.yt-dlp}/bin:${pkgs.ffmpeg}/bin:${genRss}/bin

    # Ensure NFS root exists (webhook user must have write perms on parent)
    mkdir -p "${podcastDir}"

    export XDG_CACHE_HOME=${podcastDir}/.cache
    mkdir -p "$XDG_CACHE_HOME"

    URL=$1
    if [ -z "$URL" ]; then echo "Error: No URL provided."; exit 1; fi

    cd ${podcastDir}

    yt-dlp \
      --extract-audio --audio-format mp3 --write-description --add-metadata \
      --embed-thumbnail --restrict-filenames --progress --no-playlist \
      --remote-components ejs:github \
      -o "%(title)s.%(ext)s" \
      "$URL"

    gen-rss \
      --dir "${podcastDir}" \
      --out "${podcastDir}/feed.xml" \
      --url "https://${domain}" \
      --title "My YouTube Drops"
  '';

  # 3. Playlist Downloader
  playlistDownloader = pkgs.writeShellScriptBin "playlist-downloader" ''
    exec 1> >(${pkgs.util-linux}/bin/logger -t podcast-playlist) 2>&1
    export PATH=$PATH:${pkgs.yt-dlp}/bin:${pkgs.ffmpeg}/bin:${genRss}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.coreutils}/bin

    # Ensure NFS root exists
    mkdir -p "${podcastDir}"

    export XDG_CACHE_HOME=${podcastDir}/.cache
    mkdir -p "$XDG_CACHE_HOME"

    URL=$1
    if [ -z "$URL" ]; then echo "Error: No URL provided."; exit 1; fi

    cd ${podcastDir}

    echo "Fetching playlist metadata..."

    PL_TITLE=$(yt-dlp --flat-playlist --print "playlist_title" "$URL" | head -n 1)

    if [ -z "$PL_TITLE" ]; then
        PL_TITLE="playlist-$(date +%s)"
    fi

    # Robust Slugify (sed/tr only)
    SLUG=$(echo "$PL_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{1,\}/-/g' | sed 's/^-\|-$//g')

    if [ -z "$SLUG" ]; then
        SLUG="playlist-$(date +%s)"
    fi

    TARGET_DIR="${podcastDir}/$SLUG"
    mkdir -p "$TARGET_DIR"

    echo "Downloading playlist '$PL_TITLE' to '$TARGET_DIR'..."

    yt-dlp \
      --extract-audio --audio-format mp3 --write-description --add-metadata \
      --embed-thumbnail --restrict-filenames --progress --yes-playlist \
      --ignore-errors --remote-components ejs:github \
      -o "$TARGET_DIR/%(title)s.%(ext)s" \
      "$URL"

    XML_FILE="${podcastDir}/$SLUG.xml"
    WEB_URL="https://${domain}/$SLUG"

    echo "Generating RSS feed at $XML_FILE..."

    gen-rss \
      --dir "$TARGET_DIR" \
      --out "$XML_FILE" \
      --url "$WEB_URL" \
      --title "$PL_TITLE"

    echo "RSS Generated. Sending notification..."

    curl -X POST "${gotifyUrl}?token=${gotifyToken}" \
      -F "title=Podcast Ready: $PL_TITLE" \
      -F "message=Playlist downloaded. Feed available at: https://${domain}/$SLUG.xml" \
      -F "priority=5"

    echo "Done."
  '';
in {
  # Enable the core Nginx infrastructure module
  homelab.nginx.enable = true;

  environment.systemPackages = lib.mkOrder 2500 [
    pkgs.yt-dlp
    pkgs.ffmpeg
    pkgs.curl
    pkgs.jq
    genRss
    downloader
    playlistDownloader
  ];

  # 4. Directory Permissions
  # REMOVED: systemd.tmpfiles.rules to avoid creating local dirs over NFS mounts.
  # Rely on the scripts 'mkdir -p' or manual creation.

  # 5. Webhook Service
  services.webhook = {
    enable = true;
    port = 9000;
    openFirewall = true;
    hooks = {
      download-audio = {
        execute-command = "${downloader}/bin/podcast-downloader";
        command-working-directory = podcastDir;
        pass-arguments-to-command = [
          {
            source = "payload";
            name = "url";
          }
        ];
      };
      download-playlist = {
        execute-command = "${playlistDownloader}/bin/playlist-downloader";
        command-working-directory = podcastDir;
        pass-arguments-to-command = [
          {
            source = "payload";
            name = "url";
          }
        ];
      };
    };
  };

  # Ensure Webhook doesn't start until NFS is ready.
  # NB: RequiresMountsFor is a [Unit] key. Placed in serviceConfig ([Service])
  # systemd silently IGNORES it ("Unknown key 'RequiresMountsFor' in section
  # [Service], ignoring") — it must live in unitConfig (forgejo#3).
  systemd.services.webhook = {
    serviceConfig = {
      User = lib.mkForce "nginx";
      Group = lib.mkForce "nginx";
    };
    unitConfig.RequiresMountsFor = "/mnt/data";
  };

  # 6. SOPS Secret
  # REMOVED: Managed centrally by homelab.nginx

  # The podcast files live on tower NFS, but doc1's nginx fronts every doc1 site
  # (nix-mirror included) and must not depend on tower. Serve them from a
  # loopback-only static server that owns the NFS dependency; nginx proxies to
  # it. Tower down = podcast.ablz.au 502s, nothing else. Until 2026-10-08 nginx
  # itself had RequiresMountsFor=/mnt/data, so a power cut that left tower off
  # took all of doc1's nginx down. See docs/wiki/infrastructure/tower-boot-race.md.
  #
  # #257: /mnt is blanked and only the data share is bound back, read-only.
  # forgejo#3: bind the stable NFS *mount root* (/mnt/data), NOT the
  # podcastDir leaf. Unraid's /mnt/user shfs reassigns the Podcasts directory
  # inode on every write (yt-dlp drops straight into it, plus the mover), so
  # that subdir's NFS filehandle flaps stale and a leaf bind fails namespace
  # setup (226/NAMESPACE). The mount-root handle is fixed at mount time; the
  # server resolves the podcast subdir lazily per request. Read-only because
  # it only reads — the downloader (webhook.service) writes in its own namespace.
  systemd.services.podcast-static = {
    description = "Static file server for podcast.ablz.au (loopback)";
    wantedBy = ["multi-user.target"];
    unitConfig.RequiresMountsFor = ["/mnt/data"];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.darkhttpd)
        podcastDir
        "--addr 127.0.0.1"
        "--port ${toString staticPort}"
        "--no-server-id"
        "--mimetypes ${podcastMimeTypes}"
      ];
      DynamicUser = true;
      Restart = "always";
      RestartSec = 10;
      TemporaryFileSystem = "/mnt";
      BindReadOnlyPaths = ["/mnt/data"];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      CapabilityBoundingSet = "";
    };
  };

  homelab.nfsWatchdog.podcast-static.path = podcastDir;

  # 7. Nginx Configuration
  services.nginx = {
    virtualHosts."${domain}" = {
      forceSSL = true;
      useACMEHost = domain;

      # darkhttpd lists directories itself (the old nginx autoindex) and maps
      # .xml to application/rss+xml via podcastMimeTypes.
      locations."/".proxyPass = "http://127.0.0.1:${toString staticPort}";
    };
  };

  # 8. ACME Certificate
  # Just request the cert; credentials & provider are inherited from defaults.
  security.acme.certs."${domain}" = {
    inherit domain;
    group = "nginx";
  };
}
