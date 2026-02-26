{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.smokeping;
  smokepingHome = "/var/lib/smokeping";
in {
  options.homelab.services.smokeping = {
    enable = lib.mkEnableOption "Smokeping network latency monitor";
  };

  config = lib.mkIf cfg.enable {
    services = {
      smokeping = {
        enable = true;
        hostName = "ping.ablz.au";
        host = null;
        cgiUrl = "https://ping.ablz.au/smokeping.fcgi";
        owner = "abl030";
        ownerEmail = "admin@ablz.au";
        webService = false; # We handle nginx via localProxy

        probeConfig = ''
          + FPing
          binary = ${config.security.wrapperDir}/fping

          + FPing6
          binary = ${config.security.wrapperDir}/fping
          protocol = 6

          + DNS
          binary = ${pkgs.dnsutils}/bin/dig
          lookup = google.com
          pings = 5
          step = 300
        '';

        targetConfig = ''
          probe = FPing
          menu = Top
          title = Network Latency Grapher
          remark = Homelab network monitoring

          + InternetSites
          menu = Internet Sites
          title = Internet Sites

          ++ Google
          menu = Google
          title = google.com
          host = google.com

          ++ Cloudflare
          menu = Cloudflare
          title = cloudflare.com
          host = cloudflare.com

          ++ Youtube
          menu = YouTube
          title = youtube.com
          host = youtube.com

          + DNS
          menu = DNS
          title = DNS Servers

          ++ GoogleDNS
          menu = Google DNS
          title = Google DNS 8.8.8.8
          host = 8.8.8.8

          ++ CloudflareDNS
          menu = Cloudflare DNS
          title = Cloudflare DNS 1.1.1.1
          host = 1.1.1.1

          ++ Quad9
          menu = Quad9
          title = Quad9 DNS 9.9.9.9
          host = 9.9.9.9

          + DNSProbes
          menu = DNS Probes
          title = DNS Probes
          probe = DNS

          ++ GoogleDNS
          menu = Google DNS
          title = Google DNS 8.8.8.8
          host = 8.8.8.8

          ++ CloudflareDNS
          menu = Cloudflare DNS
          title = Cloudflare DNS 1.1.1.1
          host = 1.1.1.1

          ++ Quad9
          menu = Quad9
          title = Quad9 DNS 9.9.9.9
          host = 9.9.9.9
        '';
      };

      # fcgiwrap for smokeping CGI (webService=false skips this in upstream module)
      fcgiwrap.instances.smokeping = {
        process.user = "smokeping";
        process.group = "smokeping";
        socket = {inherit (config.services.nginx) user group;};
      };

      # Override localProxy's reverse-proxy vhost with fcgi serving
      nginx.virtualHosts."ping.ablz.au" = {
        locations."/" = lib.mkForce {
          root = smokepingHome;
          index = "smokeping.fcgi";
        };
        locations."/smokeping.fcgi" = {
          extraConfig = ''
            include ${config.services.nginx.package}/conf/fastcgi_params;
            fastcgi_pass unix:${config.services.fcgiwrap.instances.smokeping.socket.address};
            fastcgi_param SCRIPT_FILENAME ${smokepingHome}/smokeping.fcgi;
            fastcgi_param DOCUMENT_ROOT ${smokepingHome};
          '';
        };
      };
    };

    # nginx user needs smokeping group for fcgi socket access
    users.users.${config.services.nginx.user}.extraGroups = ["smokeping"];

    # DNS sync + ACME via localProxy, monitoring
    homelab = {
      localProxy.hosts = [
        {
          host = "ping.ablz.au";
          port = 80; # dummy — nginx serves fcgi directly, not proxied
        }
      ];
      monitoring.monitors = [
        {
          name = "Smokeping";
          url = "https://ping.ablz.au/smokeping.fcgi";
        }
      ];
    };

    # dig binary needed for DNS probe
    environment.systemPackages = [pkgs.dnsutils];
  };
}
