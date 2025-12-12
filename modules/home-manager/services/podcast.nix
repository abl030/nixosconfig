{
  config,
  pkgs,
  lib,
  ...
}: let
  podcastDir = "/var/lib/my-podcast";
  domain = "podcast.ablz.au";

  # 1. Python Script (Updated: Reads sidecar .description files)
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
      # Sort by modification time (newest first)
      files.sort(key=os.path.getmtime, reverse=True)

      for f in files:
          filename = os.path.basename(f)
          # Verify permissions
          try:
              os.chmod(f, 0o644)
          except Exception:
              pass

          url = f"{BASE_URL}/{filename}"
          stat = os.stat(f)
          size = stat.st_size
          pubDate = formatdate(stat.st_mtime)

          # Default metadata
          duration = "0"
          title = filename
          description = ""

          # 1. Try to read title/duration from MP3 tags
          try:
              audio = MP3(f)
              duration = str(int(audio.info.length))
              # TIT2 is the Title frame
              if 'TIT2' in audio:
                  title = audio['TIT2'].text[0]
          except Exception:
              pass

          # 2. Try to read description from sidecar file (reliable)
          # The downloader writes 'Title.description' alongside 'Title.mp3'
          base_path = os.path.splitext(f)[0]
          desc_path = base_path + ".description"

          if os.path.exists(desc_path):
              try:
                  with open(desc_path, "r", encoding="utf-8") as df:
                      description = df.read()
              except Exception:
                  pass

          # 3. Fallback: Try ID3 COMM tags if description is still empty
          if not description:
              try:
                  audio = MP3(f)
                  comm_frames = []
                  for key in audio.keys():
                      if key.startswith("COMM"):
                          comm_frames.append(audio[key])

                  if comm_frames:
                      # Sort by length, assume longest is the description
                      comm_frames.sort(key=lambda x: len(x.text[0]) if x.text else 0, reverse=True)
                      if comm_frames[0].text:
                          description = comm_frames[0].text[0]
              except Exception:
                  pass

          # Generate RSS Item
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

      with open(FEED_FILE, "w") as f:
          f.write(header + items + footer)

      try:
          os.chmod(FEED_FILE, 0o644)
      except Exception:
          pass
    '';

  # 2. Downloader (Updated: Writes description file)
  downloader = pkgs.writeShellScriptBin "podcast-downloader" ''
    exec 1> >(${pkgs.util-linux}/bin/logger -t podcast-dl) 2>&1
    echo "Triggered downloader with arguments: $@"

    export PATH=$PATH:${pkgs.yt-dlp}/bin:${pkgs.ffmpeg}/bin:${genRss}/bin

    # Fix permission errors by setting a writable cache directory
    export XDG_CACHE_HOME=${podcastDir}/.cache
    mkdir -p "$XDG_CACHE_HOME"

    URL=$1

    if [ -z "$URL" ]; then
      echo "Error: No URL provided."
      exit 1
    fi

    cd ${podcastDir}

    echo "Starting yt-dlp for $URL..."

    # Added --write-description
    yt-dlp \
      --extract-audio \
      --audio-format mp3 \
      --write-description \
      --add-metadata \
      --embed-thumbnail \
      --restrict-filenames \
      --progress \
      --no-playlist \
      -o "%(title)s.%(ext)s" \
      "$URL"

    echo "Download complete. Generating RSS..."
    gen-rss
    echo "RSS Generated. Done."
  '';
in {
  environment.systemPackages = [pkgs.yt-dlp pkgs.ffmpeg genRss downloader];

  # 3. Directory Permissions
  systemd.tmpfiles.rules = [
    "d ${podcastDir} 0755 nginx nginx -"
    "d ${podcastDir}/.cache 0755 nginx nginx -"
  ];

  # 4. Webhook Service
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

  systemd.services.webhook.serviceConfig = {
    User = lib.mkForce "nginx";
    Group = lib.mkForce "nginx";
  };

  # 5. SOPS Secret
  sops.secrets."acme-cloudflare-podcast" = {
    sopsFile = ../../../secrets/secrets/acme-cloudflare.env;
    format = "dotenv";
    owner = "acme";
    group = "nginx";
  };

  # 6. Nginx Configuration
  services.nginx = {
    enable = true;

    virtualHosts."${domain}" = {
      forceSSL = true;
      useACMEHost = domain;
      root = podcastDir;

      locations."/" = {
        extraConfig = "autoindex on;";
      };

      locations."/feed.xml" = {
        extraConfig = ''
          types { application/rss+xml xml; }
        '';
      };
    };
  };

  # 7. ACME Certificate
  security.acme.certs."${domain}" = {
    inherit domain;
    group = "nginx";
    dnsProvider = "cloudflare";
    credentialsFile = config.sops.secrets."acme-cloudflare-podcast".path;
  };
}
