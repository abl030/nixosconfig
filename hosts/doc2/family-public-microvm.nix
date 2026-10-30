# familypub — the public family-history site (family.barrett-lennard.com),
# jailed in a microvm.nix guest (Forgejo #250). Architecture, publishing,
# verification and rollback: docs/wiki/services/family-public-site.md
#
# The firewall is the network boundary. The guest has a dedicated FAMILY_DMZ
# VLAN whose pfSense rules deny RFC1918, allow egress only to Cloudflare's
# tunnel edge on 7844 (upload-limited), and terminate in a block. Visitors
# reach it only through an outbound Cloudflare Tunnel; there is no port
# forward. The one inbound path is pfSense's doc1 -> guest:22 exception, used
# by `family-public-publish` to push leak-checked exports one way.
#
# Unlike the slskd/qbt cages it has no host filesystem windows at all: the
# Nix store is the guest's own erofs image, the site lives on a block
# volume, and the tunnel credential arrives as a qemu systemd credential.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  # ens21 is Proxmox VMID 114 net3, tagged VLAN 22. Matched by MAC because it
  # was hot-plugged; doc2 takes no address on this bridge.
  uplinkMac = "bc:24:11:8e:04:3c";
  guestAddress = "192.168.22.2";
  dmzGateway = "192.168.22.1";
  fqdn = "family.barrett-lennard.com";
  siteRoot = "/srv/site";
  # Everything the publish key may touch. The volume root (with the SSH host
  # key) stays root's.
  liveDir = "${siteRoot}/live";

  # Set once the locally-managed tunnel exists in the Cloudflare account (its
  # UUID names the cloudflared unit). Until then the guest serves nothing
  # publicly; publishing into it still works.
  tunnelId = null;
  tunnelEnabled = tunnelId != null;

  # Shared with family-archive.nix on doc1 (it holds the private half in sops).
  publishKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC2DhnZtIFNL7hGcPZFnBgKBE777q2caG4Ky277YpXet doc1 family-public-publish";

  # The publish key's forced command. Three verbs and nothing else:
  #   rsync ...  upload into staging/ (write-only, confined by rrsync)
  #   activate   hard-link staging/ into a new release and swap current
  #   status     print the live release
  # Releases are hard-link snapshots: rsync replaces changed files by rename,
  # so a later upload never alters a release already being served.
  publishCommand = pkgs.writeShellApplication {
    name = "family-public-publish-command";
    runtimeInputs = with pkgs; [rsync rrsync coreutils findutils];
    text = ''
      cmd=''${SSH_ORIGINAL_COMMAND:-}
      cd ${liveDir}
      case "$cmd" in
        "rsync --server "*)
          exec rrsync -wo ${liveDir}/staging
          ;;
        activate)
          if [[ ! -f staging/index.html || ! -f staging/robots.txt ]]; then
            echo "staging has no site (index.html, robots.txt); refusing" >&2
            exit 1
          fi
          id=$(date -u +%Y%m%dT%H%M%SZ)
          cp -al staging "releases/$id"
          ln -sfn "releases/$id" current.new
          mv -T current.new current
          # Keep the live release and two before it for a quick rollback.
          find releases -mindepth 1 -maxdepth 1 -type d | sort | head -n -3 | xargs -r rm -rf --
          echo "live: $id"
          ;;
        status)
          readlink current || echo "no release yet"
          ls releases
          ;;
        *)
          echo "refused: only rsync, activate and status" >&2
          exit 1
          ;;
      esac
    '';
  };
in {
  sops.secrets."family-public/tunnel" = lib.mkIf tunnelEnabled {
    sopsFile = config.homelab.secrets.sopsFile "family-public-tunnel.json";
    format = "binary";
    # qemu runs as the microvm user and reads the file at start.
    owner = "microvm";
    mode = "0400";
  };

  systemd.network = {
    enable = true;
    netdevs."br-familypub".netdevConfig = {
      Name = "br-familypub";
      Kind = "bridge";
    };
    networks = {
      "40-br-familypub" = {
        matchConfig.Name = "br-familypub";
        networkConfig.ConfigureWithoutCarrier = true;
        linkConfig.RequiredForOnline = false;
      };
      "41-familypub-uplink" = {
        matchConfig.MACAddress = uplinkMac;
        networkConfig.Bridge = "br-familypub";
        linkConfig.RequiredForOnline = false;
      };
      "42-familypub-tap" = {
        matchConfig.Name = "vm-familypub";
        networkConfig.Bridge = "br-familypub";
        linkConfig.RequiredForOnline = false;
      };
    };
  };
  networking.networkmanager.unmanaged = [
    "mac:${uplinkMac}"
    "interface-name:br-familypub"
    "interface-name:vm-familypub"
  ];

  # No shared host paths, so microvm.nix's own lifecycle is enough (contrast
  # slskd's virtiofs owner unit).
  microvm.vms.familypub = {
    autostart = true;
    restartIfChanged = true;
    config = {
      imports = [inputs.microvm.nixosModules.microvm];

      networking = {
        hostName = "familypub";
        useDHCP = false;
        # sshd is the only listener on the DMZ address; nginx and cloudflared
        # talk over loopback. pfSense admits 22 from doc1 alone.
        firewall = {
          enable = true;
          allowedTCPPorts = [22];
        };
        # pfSense runs no ntpd; its FAMILY_DMZ rules pass UDP 123 to these only.
        timeServers = ["162.159.200.1" "162.159.200.123"];
      };
      system.stateVersion = "26.05";

      microvm = {
        hypervisor = "qemu";
        vcpu = 2;
        mem = 1536;
        vsock.cid = 22;
        # No host store share: the guest boots its own closure only, so it
        # cannot read the rest of doc2's /nix/store.
        storeOnDisk = true;
        volumes = [
          {
            # /var/lib/microvms/familypub/site.img on doc2's root disk; sparse.
            image = "site.img";
            mountPoint = siteRoot;
            size = 20480;
            fsType = "ext4";
            autoCreate = true;
          }
        ];
        credentialFiles = lib.mkIf tunnelEnabled {
          family-tunnel = config.sops.secrets."family-public/tunnel".path;
        };
        interfaces = [
          {
            type = "tap";
            id = "vm-familypub";
            mac = "02:00:00:00:22:02";
          }
        ];
      };

      fileSystems.${siteRoot}.options = ["nodev" "nosuid" "noexec"];

      systemd.network = {
        enable = true;
        networks."10-eth" = {
          matchConfig.Type = "ether";
          address = ["${guestAddress}/24"];
          routes = [{Gateway = dmzGateway;}];
          networkConfig.DNS = dmzGateway;
        };
      };

      systemd.tmpfiles.rules = [
        "d ${liveDir} 0755 publish publish -"
        "d ${liveDir}/staging 0755 publish publish -"
        "d ${liveDir}/releases 0755 publish publish -"
        "d ${siteRoot}/ssh 0700 root root -"
      ];

      users.groups.publish = {};
      users.users.publish = {
        isSystemUser = true;
        group = "publish";
        home = liveDir;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = [
          ''restrict,command="${lib.getExe publishCommand}" ${publishKey}''
        ];
      };

      services.openssh = {
        enable = true;
        openFirewall = false;
        listenAddresses = [{addr = guestAddress;}];
        # On the volume: the root disk is rebuilt every boot, and doc1 pins
        # this key.
        hostKeys = [
          {
            path = "${siteRoot}/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
        settings = {
          AllowUsers = ["publish"];
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
          AllowTcpForwarding = false;
          AllowAgentForwarding = false;
          X11Forwarding = false;
        };
      };
      systemd.services.sshd.unitConfig.RequiresMountsFor = [siteRoot];
      # rsync must be on the publish user's PATH for the server side.
      environment.systemPackages = [pkgs.rsync pkgs.iproute2];

      # The guest has no management plane: forward the journal to the serial
      # console, which doc2's microvm@familypub journal (and Loki) keeps.
      services.journald.settings.Journal = {
        ForwardToConsole = true;
        MaxLevelConsole = "info";
      };

      services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        # Requests come only from cloudflared on loopback, so the visitor is
        # Cloudflare's CF-Connecting-IP header; rate-limit per visitor, not
        # per tunnel. 429 is what agents expect, never a challenge page.
        appendHttpConfig = ''
          map $http_cf_connecting_ip $visitor {
            "" $remote_addr;
            default $http_cf_connecting_ip;
          }
          limit_req_zone $visitor zone=perip:10m rate=20r/s;
          limit_conn_zone $visitor zone=perconn:10m;
          limit_req_status 429;
          limit_conn_status 429;
          access_log off;
          error_log stderr warn;
        '';
        virtualHosts.${fqdn} = {
          default = true;
          listen = [
            {
              addr = "127.0.0.1";
              port = 8080;
            }
          ];
          root = "${liveDir}/current";
          extraConfig = ''
            limit_req zone=perip burst=100 nodelay;
            limit_conn perconn 16;
          '';
          # Headers are set per location: a nested add_header drops the
          # parent's. Cloudflare holds pages a day at the edge (s-maxage) and
          # publishing purges it; browsers revalidate after five minutes.
          locations = {
            "/" = {
              tryFiles = "$uri $uri/index.html =404";
              extraConfig = ''
                add_header Cache-Control "public, max-age=300, s-maxage=86400" always;
                add_header X-Content-Type-Options nosniff always;
                add_header Referrer-Policy same-origin always;
              '';
            };
            # Downscaled images and dumps: large and rarely changed.
            "~ ^/(o|images|api/dump)/" = {
              extraConfig = ''
                add_header Cache-Control "public, max-age=86400, s-maxage=2592000" always;
                add_header X-Content-Type-Options nosniff always;
                add_header Referrer-Policy same-origin always;
                # /o/ may hold saved third-party pages: no scripts, forms or
                # same-origin access, as on the private site.
                add_header Content-Security-Policy "sandbox; default-src 'none'; img-src data: 'self'; style-src 'unsafe-inline' data:; font-src data:; media-src 'self'" always;
              '';
            };
            "~ /\\.".return = "404";
          };
        };
      };
      systemd.services.nginx.unitConfig.RequiresMountsFor = [siteRoot];

      services.cloudflared = lib.mkIf tunnelEnabled {
        enable = true;
        tunnels.${tunnelId} = {
          credentialsFile = "/run/credentials/@system/family-tunnel";
          edgeIPVersion = "4";
          ingress.${fqdn} = "http://127.0.0.1:8080";
          default = "http_status:404";
        };
      };
    };
  };
}
