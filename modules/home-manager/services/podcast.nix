{
  pkgs,
  lib,
  ...
}: let
  # 1. Define the directory
  podcastDir = "/var/lib/my-podcast";

  # 2. Python Script to Generate RSS
  # scans the dir, reads mp3 metadata, creates feed.xml
  # 2. Python Script to Generate RSS
  genRss =
    pkgs.writers.writePython3Bin "gen-rss" {
      libraries = [pkgs.python3Packages.mutagen];
      flakeIgnore = ["E501"]; # Optional: ignore line length errors if they pop up
    } ''
      import os
      import glob
      from email.utils import formatdate
      from mutagen.mp3 import MP3
      import html

      # CHANGE THIS to your Tailscale DNS/IP
      BASE_URL = "http://192.168.1.29:8029"
      DIR = "${podcastDir}"
      FEED_FILE = os.path.join(DIR, "feed.xml")

      header = """<?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
      <title>My YouTube Drops</title>
      <description>Links dropped from CLI</description>
      <link>""" + BASE_URL + """</link>
      """

      items = ""
      # Get list of mp3s, sorted by time (newest first)
      files = glob.glob(os.path.join(DIR, "*.mp3"))
      files.sort(key=os.path.getmtime, reverse=True)

      for f in files:
          filename = os.path.basename(f)
          url = f"{BASE_URL}/{filename}"
          stat = os.stat(f)
          size = stat.st_size
          pubDate = formatdate(stat.st_mtime)

          try:
              audio = MP3(f)
              duration = str(int(audio.info.length))
              # Use ID3 title if exists, else filename
              title = audio.get('TIT2', str(filename)).text[0]
          except Exception:
              duration = "0"
              title = filename

          items += f"""
          <item>
              <title>{html.escape(title)}</title>
              <enclosure url="{url}" length="{size}" type="audio/mpeg"/>
              <guid>{url}</guid>
              <pubDate>{pubDate}</pubDate>
              <itunes:duration>{duration}</itunes:duration>
          </item>
          """

      footer = "</channel></rss>"

      with open(FEED_FILE, "w") as f:
          f.write(header + items + footer)
    '';

  # 3. Downloader Wrapper Script
  # Runs yt-dlp, tags it, moves it, regenerates RSS
  downloader = pkgs.writeShellScriptBin "podcast-downloader" ''
    export PATH=$PATH:${pkgs.yt-dlp}/bin:${pkgs.ffmpeg}/bin:${genRss}/bin

    URL=$1
    cd ${podcastDir}

    # Download: Audio only, MP3, embed metadata (thumbnail/artist), specific filename format
    # --restrict-filenames prevents weird chars in URLs
    yt-dlp \
      --extract-audio \
      --audio-format mp3 \
      --add-metadata \
      --embed-thumbnail \
      --restrict-filenames \
      -o "%(title)s.%(ext)s" \
      "$URL"

    # Regenerate RSS
    gen-rss
  '';
in {
  # Install necessary packages system-wide (optional, but good for debugging)
  environment.systemPackages = [pkgs.yt-dlp pkgs.ffmpeg genRss downloader];

  # Create the storage directory with correct permissions
  systemd.tmpfiles.rules = [
    "d ${podcastDir} 0755 caddy caddy -"
  ];

  # 4. Webhook Service
  services.webhook = {
    enable = true;
    port = 9000;
    openFirewall = true; # Open 9000 for local network/tailscale
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
        # Optional: verify secret if you want security
        # trigger-rule = { ... };
      };
    };
  };

  # Make sure webhook service can write to the directory
  systemd.services.webhook.serviceConfig = {
    User = lib.mkForce "caddy";
    Group = lib.mkForce "caddy";
  };

  # 5. Caddy Service
  services.caddy = {
    enable = true;
    virtualHosts."http://:8029" = {
      # In a real scenario, bind this to your specific Tailscale IP
      # e.g., "http://100.x.y.z:8080"

      extraConfig = ''
        root * ${podcastDir}
        file_server
      '';
    };
  };
}
