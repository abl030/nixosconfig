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

          ++ Facebook
          menu = Facebook
          title = Facebook
          host = facebook.com

          ++ Youtube
          menu = YouTube
          title = YouTube
          host = youtube.com

          ++ JupiterBroadcasting
          menu = JupiterBroadcasting
          title = JupiterBroadcasting
          host = jupiterbroadcasting.com

          ++ GoogleSearch
          menu = Google
          title = google.com
          host = google.com

          ++ GoogleSearchIpv6
          menu = Google
          probe = FPing6
          title = ipv6.google.com
          host = ipv6.google.com

          ++ linuxserverio
          menu = linuxserver.io
          title = linuxserver.io
          host = linuxserver.io

          + Europe
          menu = Europe
          title = European Connectivity

          ++ Germany
          menu = Germany
          title = The Fatherland

          +++ TelefonicaDE
          menu = Telefonica DE
          title = Telefonica DE
          host = www.telefonica.de

          ++ Switzerland
          menu = Switzerland
          title = Switzerland

          +++ CernIXP
          menu = CernIXP
          title = Cern Internet eXchange Point
          host = cixp.web.cern.ch

          +++ SBB
          menu = SBB
          title = SBB
          host = www.sbb.ch

          ++ UK
          menu = United Kingdom
          title = United Kingdom

          +++ CambridgeUni
          menu = Cambridge
          title = Cambridge
          host = cam.ac.uk

          +++ UEA
          menu = UEA
          title = UEA
          host = uea.ac.uk

          + USA
          menu = North America
          title = North American Connectivity

          ++ MIT
          menu = MIT
          title = Massachusetts Institute of Technology Webserver
          host = web.mit.edu

          ++ IU
          menu = IU
          title = Indiana University
          host = www.indiana.edu

          ++ UCB
          menu = U. C. Berkeley
          title = U. C. Berkeley Webserver
          host = www.berkeley.edu

          ++ UCSD
          menu = U. C. San Diego
          title = U. C. San Diego Webserver
          host = ucsd.edu

          ++ UMN
          menu = University of Minnesota
          title = University of Minnesota
          host = twin-cities.umn.edu

          ++ OSUOSL
          menu = Oregon State University Open Source Lab
          title = Oregon State University Open Source Lab
          host = osuosl.org

          + DNS
          menu = DNS
          title = DNS

          ++ GoogleDNS1
          menu = Google DNS 1
          title = Google DNS 8.8.8.8
          host = 8.8.8.8

          ++ GoogleDNS2
          menu = Google DNS 2
          title = Google DNS 8.8.4.4
          host = 8.8.4.4

          ++ OpenDNS1
          menu = OpenDNS1
          title = OpenDNS1
          host = 208.67.222.222

          ++ OpenDNS2
          menu = OpenDNS2
          title = OpenDNS2
          host = 208.67.220.220

          ++ CloudflareDNS1
          menu = Cloudflare DNS 1
          title = Cloudflare DNS 1.1.1.1
          host = 1.1.1.1

          ++ CloudflareDNS2
          menu = Cloudflare DNS 2
          title = Cloudflare DNS 1.0.0.1
          host = 1.0.0.1

          ++ L3-1
          menu = Level3 DNS 1
          title = Level3 DNS 4.2.2.1
          host = 4.2.2.1

          ++ L3-2
          menu = Level3 DNS 2
          title = Level3 DNS 4.2.2.2
          host = 4.2.2.2

          ++ Quad9
          menu = Quad9
          title = Quad9 DNS 9.9.9.9
          host = 9.9.9.9

          + DNSProbes
          menu = DNS Probes
          title = DNS Probes
          probe = DNS

          ++ GoogleDNS1
          menu = Google DNS 1
          title = Google DNS 8.8.8.8
          host = 8.8.8.8

          ++ GoogleDNS2
          menu = Google DNS 2
          title = Google DNS 8.8.4.4
          host = 8.8.4.4

          ++ OpenDNS1
          menu = OpenDNS1
          title = OpenDNS1
          host = 208.67.222.222

          ++ OpenDNS2
          menu = OpenDNS2
          title = OpenDNS2
          host = 208.67.220.220

          ++ CloudflareDNS1
          menu = Cloudflare DNS 1
          title = Cloudflare DNS 1.1.1.1
          host = 1.1.1.1

          ++ CloudflareDNS2
          menu = Cloudflare DNS 2
          title = Cloudflare DNS 1.0.0.1
          host = 1.0.0.1

          ++ L3-1
          menu = Level3 DNS 1
          title = Level3 DNS 4.2.2.1
          host = 4.2.2.1

          ++ L3-2
          menu = Level3 DNS 2
          title = Level3 DNS 4.2.2.2
          host = 4.2.2.2

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
