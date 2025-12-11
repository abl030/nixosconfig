{
  config,
  pkgs,
  lib,
  ...
}: let
  podcastDir = "/var/lib/my-podcast";
  domain = "podcast.ablz.au";

  # 1. Python Script (Updated for HTTPS domain)
  # 1. Python Script (Updated for HTTPS domain + Linter Fix)
  genRss =
    pkgs.writers.writePython3Bin "gen-rss" {
      libraries = [pkgs.python3Packages.mutagen];
      flakeIgnore = ["E501"];
    } ''
      import os
      import glob
      from email.utils import formatdate
      from mutagen.mp3 import MP3
      import html

      # NOW USES HTTPS DOMAIN
      BASE_URL = "https://${domain}"
      DIR = "${podcastDir}"
      FEED_FILE = os.path.join(DIR, "feed.xml")

      header = """<?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
      <title>My YouTube Drops</title>
      <description>Links dropped from CLI</description>
      <language>en-us</language>
      <link>""" + BASE_URL + """</link>
      """

      items = ""
      files = glob.glob(os.path.join(DIR, "*.mp3"))
      files.sort(key=os.path.getmtime, reverse=True)

      for f in files:
          filename = os.path.basename(f)
          # Verify permissions (fix for nginx user if needed)
          try:
              os.chmod(f, 0o644)
          except Exception:
              pass

          url = f"{BASE_URL}/{filename}"
          stat = os.stat(f)
          size = stat.st_size
          pubDate = formatdate(stat.st_mtime)

          try:
              audio = MP3(f)
              duration = str(int(audio.info.length))
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

      # Ensure Nginx can read the feed
      try:
          os.chmod(FEED_FILE, 0o644)
      except Exception:
          pass
    '';

  # 2. Downloader (Same as before)
  downloader = pkgs.writeShellScriptBin "podcast-downloader" ''
    export PATH=$PATH:${pkgs.yt-dlp}/bin:${pkgs.ffmpeg}/bin:${genRss}/bin

    URL=$1
    cd ${podcastDir}

    yt-dlp \
      --extract-audio \
      --audio-format mp3 \
      --add-metadata \
      --embed-thumbnail \
      --restrict-filenames \
      -o "%(title)s.%(ext)s" \
      "$URL"

    gen-rss
  '';
in {
  environment.systemPackages = [pkgs.yt-dlp pkgs.ffmpeg genRss downloader];

  # 3. Directory Permissions (Now owned by nginx)
  systemd.tmpfiles.rules = [
    "d ${podcastDir} 0755 nginx nginx -"
  ];

  # 4. Webhook Service (Runs as nginx)
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
    };
  };

  # Force webhook to run as nginx so files are created with correct ownership
  systemd.services.webhook.serviceConfig = {
    User = lib.mkForce "nginx";
    Group = lib.mkForce "nginx";
  };

  # 5. SOPS Secret for Cloudflare
  # We define this here to ensure this module is self-contained,
  # though it might overlap with your cache config (which is fine).
  sops.secrets."acme-cloudflare-podcast" = {
    sopsFile = ../../../secrets/secrets/acme-cloudflare.env; # Adjust path to your actual secrets location
    format = "dotenv";
    owner = "acme"; # ACME service needs to read this
    group = "nginx";
  };

  # 6. Nginx Configuration (Replaces Caddy)
  services.nginx = {
    enable = true; # Already enabled by your cache, but safe to restate

    virtualHosts."${domain}" = {
      forceSSL = true;
      useACMEHost = domain; # Use the cert defined below
      root = podcastDir;

      locations."/" = {
        # Allow autoindexing so you can browse the files if you want
        extraConfig = "autoindex on;";
      };

      # Force correct content-type for the RSS feed
      locations."/feed.xml" = {
        extraConfig = ''
          types { application/rss+xml xml; }
        '';
      };
    };
  };

  # 7. ACME Certificate (DNS-01 Challenge)
  security.acme.certs."${domain}" = {
    domain = domain;
    group = "nginx";
    dnsProvider = "cloudflare";
    credentialsFile = config.sops.secrets."acme-cloudflare-podcast".path;
  };
}
