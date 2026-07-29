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
  lib,
  pkgs,
  ...
}: let
  dmzUplink = "ens20";
  guestAddress = "192.168.21.2";
  dmzGateway = "192.168.21.1";
  storageMount = "/srv/slskd-storage";
  storageUuid = "8b2fb269-84d2-4480-8fea-34bcf1d59b42";
  hostStateDir = "/mnt/virtio/slskd";
  guestStateDir = "/var/lib/slskd";
  downloadDir = "/mnt/virtio/music/slskd";
  musicDir = "/mnt/virtio/Music/Beets";
  slskdUid = 988;
  musicImportGid = 968;

  # Only the read-only library remains a nested export from doc2's outer
  # virtiofs mount. It must retain O_PATH descriptors instead of asking the
  # outer FUSE filesystem for export file handles. The Nix store is local ext4
  # and the secret is local ramfs, so leave their normal `prefer` behavior
  # intact; forcing `never` there would needlessly pin large local trees.
  #
  # The writable state and download shares are bind mounts backed by a dedicated
  # ext4 block disk. Keep `prefer` for those shares so virtiofsd uses stable
  # ext4 file handles. Only the still-nested library is rewritten to `never`.
  # Applying `never` to the writable shares was the issue #51 bug: it
  # pinned O_PATH descriptors into FUSE and served sticky ENOENT/ESTALE after an
  # external directory replacement.
  # See docs/wiki/infrastructure/virtiofs-nested-reexport-stale-pins.md (#51).
  virtiofsdNestedSafe = pkgs.writeShellScriptBin "virtiofsd" ''
    nested_fuse=false
    for arg in "$@"; do
      case "$arg" in
        --shared-dir=${musicDir}) nested_fuse=true ;;
      esac
    done

    args=()
    for arg in "$@"; do
      if "$nested_fuse"; then
        case "$arg" in
          --inode-file-handles=prefer) args+=(--inode-file-handles=never) ;;
          --posix-acl | --xattr) ;;
          *) args+=("$arg") ;;
        esac
      else
        args+=("$arg")
      fi
    done
    exec ${lib.getExe pkgs.virtiofsd} "''${args[@]}"
  '';

  # Keep the parent guest's activation transaction coupled to every local
  # lifecycle override on its virtiofsd instance.
  virtiofsdLifecycle = {
    bindsTo = ["microvm@slskd.service"];
    requires = [
      "mnt-virtio-slskd.mount"
      "mnt-virtio-music-slskd.mount"
    ];
    after = [
      "mnt-virtio-slskd.mount"
      "mnt-virtio-music-slskd.mount"
    ];
    unitConfig = {
      ConditionPathExists = "/run/secrets/slskd/env";
      RequiresMountsFor = [hostStateDir downloadDir musicDir "/run/secrets/slskd"];
    };
  };
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

  # Dedicated 300 GiB sparse 64K-zvol/ext4 disk for the hostile downloader's
  # SQLite state and mutable handoff tree. The underlying ext4 filesystem is
  # mounted outside /mnt/virtio, then bind-mounted over the legacy paths so
  # Cratedigger's event-stamped paths remain unchanged. `nofail` lets doc2 boot
  # for recovery if the disk is absent; explicit Requires= dependencies below
  # keep slskd failed closed instead of falling through to the old virtiofs data.
  fileSystems.${storageMount} = {
    device = "/dev/disk/by-uuid/${storageUuid}";
    fsType = "ext4";
    options = [
      "nofail"
      "noatime"
      "nodev"
      "nosuid"
      "noexec"
      "errors=remount-ro"
      "x-systemd.device-timeout=30s"
    ];
  };
  fileSystems.${hostStateDir} = {
    device = "${storageMount}/state";
    fsType = "none";
    options = [
      "bind"
      "nofail"
      "x-systemd.requires-mounts-for=${storageMount}"
    ];
  };
  fileSystems.${downloadDir} = {
    device = "${storageMount}/downloads";
    fsType = "none";
    options = [
      "bind"
      "nofail"
      "x-systemd.requires-mounts-for=${storageMount}"
    ];
  };

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
    # doc2's PostgreSQL nspawn containers use NixOS' container network setup
    # to assign their fixed 10.20.0.0/24 host routes. Enabling networkd for the
    # slskd bridge otherwise lets the stock 80-container-ve.network seize every
    # ve-* link, replace those routes with random private subnets, and take all
    # database-backed services offline. Keep networkd away from nspawn veths;
    # the container units remain their sole network owner.
    "10-nspawn-veth-unmanaged" = {
      matchConfig.Name = "ve-*";
      linkConfig.Unmanaged = true;
    };
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
  # NetworkManager already provides network-online; networkd must not wait for
  # an address that the containment boundary deliberately forbids.
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;

  # microvm.nix runs one virtiofsd process per guest. Gate it on every shared
  # host path and the decrypted secret; microvm@slskd requires this daemon.
  # This sops-nix version installs secrets during activation rather than through
  # a long-lived systemd unit, so use a path condition instead of a dangling
  # dependency on sops-install-secrets.service.
  #
  # NixOS switch-to-configuration submits and waits only for jobs it selected
  # directly. It must select both units: stopping only the parent lets PartOf=
  # enqueue a child stop that is not part of the wait barrier, so the subsequent
  # parent start can cancel that pending stop and reuse dead virtiofs sockets.
  # Keep the child's normal restartIfChanged=true, and make any exact child
  # drop-in or wrapper change also select the parent. The stop barrier then waits
  # for guest -> virtiofsd, and the start barrier follows virtiofsd -> guest.
  systemd.services."microvm@slskd".restartTriggers = [
    virtiofsdNestedSafe
    config.systemd.units."microvm-virtiofsd@slskd.service".unit
  ];
  systemd.services."microvm-virtiofsd@slskd" = virtiofsdLifecycle;

  assertions = [
    {
      assertion = config.systemd.services."microvm-virtiofsd@slskd".restartIfChanged;
      message = "slskd virtiofsd must be a directly tracked activation job";
    }
    {
      assertion =
        lib.elem
        config.systemd.units."microvm-virtiofsd@slskd.service".unit
        config.systemd.services."microvm@slskd".restartTriggers;
      message = "slskd parent must track the exact generated virtiofsd unit";
    }
  ];

  # Every Cratedigger unit that binds the handoff tree must also fail closed.
  # Otherwise a missing block disk would expose the old nested mountpoint and
  # let them move files into a hidden, divergent tree while slskd stays down.
  systemd.services.cratedigger = {
    requires = ["mnt-virtio-music-slskd.mount"];
    after = ["mnt-virtio-music-slskd.mount"];
    unitConfig.RequiresMountsFor = [downloadDir];
  };
  systemd.services.cratedigger-web = {
    requires = ["mnt-virtio-music-slskd.mount"];
    after = ["mnt-virtio-music-slskd.mount"];
    unitConfig.RequiresMountsFor = [downloadDir];
  };
  systemd.services.cratedigger-importer = {
    requires = ["mnt-virtio-music-slskd.mount"];
    after = ["mnt-virtio-music-slskd.mount"];
    unitConfig.RequiresMountsFor = [downloadDir];
  };
  systemd.services.cratedigger-import-preview-worker = {
    requires = ["mnt-virtio-music-slskd.mount"];
    after = ["mnt-virtio-music-slskd.mount"];
    unitConfig.RequiresMountsFor = [downloadDir];
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
      # The two doc2 panics after this guest was introduced both implicated
      # Cloud Hypervisor's _net0_qp2 host thread. Two vCPUs generate only the
      # qp0/qp1 pair topology proven stable by the qbt microVM; slskd does not
      # need four vCPUs. See the 2026-07-22 RCA in the cage wiki.
      vcpu = 2;
      mem = 6144;
      vsock.cid = 21;
      virtiofsd.package = virtiofsdNestedSafe;
      shares = [
        {
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
          readOnly = true;
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

    # Host mount flags do not propagate through virtiofs. Enforce these in the
    # hostile guest too: slskd needs data and SQLite access, never execution
    # from its mutable state or Internet-controlled download tree.
    fileSystems.${guestStateDir}.options = lib.mkAfter [
      "nodev"
      "nosuid"
      "noexec"
    ];
    fileSystems.${downloadDir}.options = lib.mkAfter [
      "nodev"
      "nosuid"
      "noexec"
    ];

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
