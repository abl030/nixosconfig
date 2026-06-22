# homelab.services.servarr — the *arr stack (Radarr / Sonarr / Prowlarr) as native
# upstream services, wired into the fleet's reverse-proxy + monitoring. Designed to
# run on any host (group/paths via options).
#
# The torrent client (qBittorrent) is SEPARATE: an isolated microvm.nix guest on the
# Torrent_DMZ VLAN (see hosts/servarr/qbt-microvm.nix). This module also fronts its
# WebUI at qbt.ablz.au so qbt is reachable LAN-wide through nginx like every other
# service — never by IP.
#
# Rules: docs/wiki/nixos-service-modules.md. Design + build: Forgejo issue #1.
# Full architecture, migration, cutover + gotchas: docs/wiki/services/servarr-and-qbt-cage.md
{
  config,
  lib,
  hostConfig,
  ...
}: let
  cfg = config.homelab.services.servarr;
in {
  options.homelab.services.servarr = {
    enable = lib.mkEnableOption "the *arr stack (Radarr/Sonarr/Prowlarr) + the qBittorrent reverse-proxy";

    mediaGroup = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Shared group Radarr/Sonarr run as, for library access on the NFS mount.";
    };

    mediaPath = lib.mkOption {
      type = lib.types.str;
      default = "/media/data";
      description = ''
        Library root the *arr apps read/write (watched by nfsWatchdog). The mount
        itself (tower NFS) is defined in the host config, not here.
      '';
    };

    qbtUpstream = lib.mkOption {
      type = lib.types.str;
      default = "192.168.20.2";
      description = ''
        Address qbt.ablz.au proxies to (the qBittorrent microVM WebUI).
        DNS-First exception (rules-doc rule 4): the qbt guest lives on the isolated
        Torrent_DMZ VLAN with no FQDN of its own — by design it's egress-VPN-only and
        default-deny, so it has no localProxy/MagicDNS name. Its IP is fixed by the
        cage; servarr's nginx reaches it via the single pfSense .4→.20.2:8080 inbound
        exception.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.mediaGroup} = {};
    # Host admin joins the media group so they can inspect the library without sudo.
    users.users.${hostConfig.user}.extraGroups = [cfg.mediaGroup];

    # The *arr hardlink completed downloads into the library. qbt + NZBGet write those
    # to the NFS scratch (/media/data/Media/Temp) as gid 100 (`users`, the dir's group,
    # mode 2775/setgid). The *arr run as `media` (gid 998), so give them `users` as a
    # supplementary group → group-write on the gid-100 downloads → hardlink import works
    # (fs.protected_hardlinks otherwise blocks linking a file you can't write). Forgejo #1.
    users.users.radarr.extraGroups = ["users"];
    users.users.sonarr.extraGroups = ["users"];

    # The *arr trio (upstream modules; state in /var/lib/<app>). NOT openFirewall —
    # reached ONLY via the localProxy nginx below, never by IP. The migrated config.xml
    # must set BindAddress=127.0.0.1: tailscale0 is a trusted firewall interface, so a
    # 0.0.0.0 bind would be reachable tailnet-wide even with no open LAN port. radarr/
    # sonarr join `media` for library access; prowlarr needs none.
    services.radarr = {
      enable = true;
      group = cfg.mediaGroup;
    };
    services.sonarr = {
      enable = true;
      group = cfg.mediaGroup;
    };
    services.prowlarr.enable = true;

    homelab = {
      # LAN-wide *.ablz.au via this host's nginx + ACME. Loopback upstreams for the
      # *arr trio; qbt.ablz.au proxies into the DMZ microVM (see qbtUpstream).
      localProxy.hosts = [
        {
          host = "radarr.ablz.au";
          port = 7878;
        }
        {
          host = "sonarr.ablz.au";
          port = 8989;
        }
        {
          host = "prowlarr.ablz.au";
          port = 9696;
        }
        {
          host = "qbt.ablz.au";
          port = 8080;
          upstreamHost = cfg.qbtUpstream;
        }
      ];

      monitoring.monitors = [
        {
          name = "Radarr (LAN)";
          url = "https://radarr.ablz.au/ping";
        }
        {
          name = "Sonarr (LAN)";
          url = "https://sonarr.ablz.au/ping";
        }
        {
          name = "Prowlarr (LAN)";
          url = "https://prowlarr.ablz.au/ping";
        }
        {
          name = "qBittorrent (LAN)";
          url = "https://qbt.ablz.au/";
        }
      ];

      # errorPatterns is REQUIRED (errorPatternsCheck) once localProxy.hosts is set,
      # and left EMPTY deliberately: the rules require patterns be VERIFIED against
      # ~30 days of Loki history before committing, and this host isn't deployed yet.
      # Process/WebUI-down is caught by the Kuma monitors above; refine with real *arr
      # failure fingerprints (DB malformed, migration failure) from Loki post-deploy.
      # Deep write-path probes are likewise deferred to post-deploy (need the API keys
      # in sops first); the migrated DBs come over working, so the shallow monitors
      # cover the initial cutover. See docs/wiki/nixos-service-modules.md.
      monitoring.errorPatterns = [];

      # Library is the tower NFS mount; restart the *arr apps if it goes stale.
      nfsWatchdog.radarr.path = cfg.mediaPath;
      nfsWatchdog.sonarr.path = cfg.mediaPath;
    };
  };
}
