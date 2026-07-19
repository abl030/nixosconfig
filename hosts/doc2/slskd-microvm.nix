# slskd — Internet-facing Soulseek client jailed in a microvm.nix guest (#38).
# Architecture, migration, rollback, and verification:
#   docs/wiki/services/slskd-cage.md
#
# The firewall is the network boundary. The guest has a dedicated SLSKD_DMZ
# VLAN whose pfSense rules deny RFC1918 access, policy-route
# egress through USA-preferred AirVPN with Netherlands fallback, and terminate
# in a kill switch. doc2 may reach only the slskd API through a single pfSense
# LAN exception. The AirVPN USA port forward targets the guest directly.
{
  config,
  inputs,
  pkgs,
  ...
}: let
  dmzUplink = "ens20";
  guestAddress = "192.168.21.2";
  dmzGateway = "192.168.21.1";
  hostStateDir = "/mnt/virtio/slskd";
  guestStateDir = "/var/lib/slskd";
  downloadDir = "/mnt/virtio/music/slskd";
  musicDir = "/mnt/virtio/Music/Beets";
  slskdUid = 988;
  musicImportGid = 968;
in {
  imports = [inputs.microvm.nixosModules.host];

  # doc2 is itself a Proxmox VM. VMID 114 must use cpu=host with Proxmox's
  # +nested-virt flag so AMD-V reaches this guest; boot.kernelModules then
  # materialises /dev/kvm.
  boot.kernelModules = ["kvm-amd"];

  # Keep host ownership stable across the native-service -> guest cutover.
  # virtiofs passes numeric IDs through, so these IDs must match in the guest.
  users.groups.music-import.gid = musicImportGid;
  users.users = {
    slskd = {
      uid = slskdUid;
      isSystemUser = true;
      group = "music-import";
    };
    abl030.extraGroups = ["music-import"];
  };

  systemd.tmpfiles.rules = [
    "d ${hostStateDir} 0755 slskd music-import -"
    "d ${downloadDir} 0770 slskd music-import -"
    "d ${downloadDir}/incomplete 0770 slskd music-import -"
  ];

  sops.secrets."slskd/env" = {
    sopsFile = config.homelab.secrets.sopsFile "slskd.env";
    format = "dotenv";
    owner = "slskd";
    mode = "0400";
  };

  # ens20 is Proxmox VMID 114 net2, tagged VLAN 21. doc2 takes no address on
  # this bridge: it is only an L2 conduit from the slskd tap to SLSKD_DMZ.
  systemd.network.enable = true;
  systemd.network.netdevs."br-slskd".netdevConfig = {
    Name = "br-slskd";
    Kind = "bridge";
  };
  systemd.network.networks = {
    "40-br-slskd" = {
      matchConfig.Name = "br-slskd";
      networkConfig.ConfigureWithoutCarrier = true;
      linkConfig.RequiredForOnline = false;
    };
    "41-slskd-uplink" = {
      matchConfig.Name = dmzUplink;
      networkConfig.Bridge = "br-slskd";
      linkConfig.RequiredForOnline = false;
    };
    "42-slskd-tap" = {
      matchConfig.Name = "vm-slskd";
      networkConfig.Bridge = "br-slskd";
      linkConfig.RequiredForOnline = false;
    };
  };
  networking.networkmanager.unmanaged = [
    "interface-name:${dmzUplink}"
    "interface-name:br-slskd"
    "interface-name:vm-slskd"
  ];
  # networkd owns only the IP-less guest bridge on this NetworkManager host.
  # Exclude those links explicitly so network-online never burns its 120-second
  # timeout waiting for an address that the containment boundary forbids.
  systemd.network.wait-online = {
    anyInterface = true;
    ignoredInterfaces = [dmzUplink "br-slskd" "vm-slskd"];
  };

  # microvm.nix runs one virtiofsd process per guest. Gate it on every shared
  # host path and the decrypted secret; microvm@slskd requires this daemon.
  # This sops-nix version installs secrets during activation rather than through
  # a long-lived systemd unit, so use a path condition instead of a dangling
  # dependency on sops-install-secrets.service.
  systemd.services."microvm-virtiofsd@slskd" = {
    unitConfig = {
      ConditionPathExists = "/run/secrets/slskd/env";
      RequiresMountsFor = [hostStateDir downloadDir musicDir "/run/secrets/slskd"];
    };
  };

  homelab = {
    localProxy.hosts = [
      {
        host = "slskd.ablz.au";
        port = 5030;
        upstreamHost = guestAddress;
      }
    ];
    monitoring.monitors = [
      {
        name = "slskd";
        url = "https://slskd.ablz.au/health";
      }
    ];
  };

  microvm.vms.slskd.config = {
    imports = [inputs.microvm.nixosModules.microvm];

    networking = {
      hostName = "slskd";
      useDHCP = false;
      firewall = {
        enable = true;
        # 5030 is admitted only from doc2 by pfSense. 50300 is the Soulseek
        # TCP listener reached through the USA-only AirVPN forward.
        allowedTCPPorts = [5030 50300];
      };
    };
    system.stateVersion = "26.05";

    microvm = {
      hypervisor = "cloud-hypervisor";
      vcpu = 4;
      mem = 6144;
      vsock.cid = 21;
      shares = [
        {
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }
        {
          source = hostStateDir;
          mountPoint = guestStateDir;
          tag = "slskd-state";
          proto = "virtiofs";
        }
        {
          source = downloadDir;
          mountPoint = downloadDir;
          tag = "slskd-downloads";
          proto = "virtiofs";
        }
        {
          source = musicDir;
          mountPoint = musicDir;
          tag = "slskd-library";
          proto = "virtiofs";
          readOnly = true;
        }
        {
          source = "/run/secrets/slskd";
          mountPoint = "/run/host-secrets/slskd";
          tag = "slskd-secret";
          proto = "virtiofs";
          readOnly = true;
        }
      ];
      interfaces = [
        {
          type = "tap";
          id = "vm-slskd";
          mac = "02:00:00:00:21:02";
        }
      ];
    };

    systemd.network = {
      enable = true;
      networks."10-eth" = {
        matchConfig.Type = "ether";
        address = ["${guestAddress}/24"];
        routes = [{Gateway = dmzGateway;}];
        networkConfig.DNS = dmzGateway;
      };
    };

    users.groups.music-import.gid = musicImportGid;
    users.users.slskd = {
      uid = slskdUid;
      isSystemUser = true;
      group = "music-import";
    };

    services.slskd = {
      enable = true;
      user = "slskd";
      group = "music-import";
      domain = null;
      openFirewall = false;
      environmentFile = "/run/host-secrets/slskd/env";
      settings = {
        soulseek = {
          listen_port = 50300;
          description = "NixOS slskd jailed on SLSKD_DMZ";
        };
        directories = {
          downloads = downloadDir;
          incomplete = "${downloadDir}/incomplete";
        };
        shares.directories = [musicDir];
        web = {
          port = 5030;
          ip_address = "0.0.0.0";
        };
      };
    };

    systemd.services.slskd = {
      unitConfig.RequiresMountsFor = [guestStateDir downloadDir musicDir "/run/host-secrets/slskd"];
      serviceConfig = {
        UMask = "0002";
        # The guest deliberately has no management plane. Mirror service output
        # to its serial console so the host journal remains a usable diagnostic
        # surface for this Internet-facing daemon.
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };

    # The guest has no SSH, Tailscale, fleet credentials, or management plane.
    environment.systemPackages = [pkgs.iproute2];
  };
}
