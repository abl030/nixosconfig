# qbt — the isolated qBittorrent microVM (Forgejo #1).
# Architecture + the virtiofs-over-NFS storage gotcha chain + cage details:
#   docs/wiki/services/servarr-and-qbt-cage.md
#
# This is the ONE genuinely-hostile-input box: internet-facing libtorrent with an
# inbound VPN port. So it gets VM-grade isolation via microvm.nix / cloud-
# hypervisor, nested inside servarr (tower has nested virt = Y; servarr's vCPU must
# be host-passthrough — set in the tower libvirt def at install).
#
# Containment model — the FIREWALL is the boundary, not the guest:
#   NET  — its own LAN IP on VLAN 20 (Torrent_DMZ, 192.168.20.2). pfSense policy-
#          routes it out AirVPN only + kill-switch, default-denies it to the whole
#          fleet/LAN/other VLANs, allows exactly ONE inbound (servarr → qbt:8080),
#          and forwards the AirVPN port → qbt:45726. The guest just needs a correct
#          address; all deny / VPN / kill-switch logic lives at pfSense.
#   DISK — three windows ONLY: RO /nix/store (virtiofs), a small writable state
#          volume, and /downloads = a virtiofs view of a SCRATCH SUBDIR of the
#          library fs. It never sees the library or the rest of /data. servarr
#          (trusted) hardlinks completed files from the scratch into the library.
#
# INSTALL-TIME TODO (marked inline): servarr's VLAN-20 uplink interface name
# (its 2nd vNIC, bridged to tower br0.20).
{
  lib,
  pkgs,
  inputs,
  ...
}: let
  # servarr's 2nd vNIC — attached on tower to br0.20 (VLAN 20). Confirmed at install
  # (2026-06-22): the LAN NIC is enp1s0, the VLAN-20 NIC is enp2s0 (predictable PCI
  # naming from the libvirt q35 topology; stable across NixOS versions).
  dmzUplink = "enp2s0";

  # virtiofsd over the Unraid NFS-backed scratch: that backend supports NEITHER POSIX
  # ACLs NOR user xattrs (both return EOPNOTSUPP / "Operation not supported"), but
  # microvm.nix HARDCODES `--posix-acl --xattr` on virtiofsd. So libtorrent's file ops
  # in the qbt guest failed with "Operation not supported" and downloads never wrote.
  # Wrap virtiofsd to strip those two flags (harmless for the RO /nix/store share too).
  # This keeps the cage intact — no NFS pinhole, no architecture change. See Forgejo #1.
  virtiofsdNoXattr = pkgs.writeShellScriptBin "virtiofsd" ''
    args=()
    for a in "$@"; do
      case "$a" in
        --posix-acl | --xattr) ;;
        *) args+=("$a") ;;
      esac
    done
    exec ${lib.getExe pkgs.virtiofsd} "''${args[@]}"
  '';

  # Public tracker list, baked from the `trackerslist` flake input (auto-refreshed by
  # the nightly rolling-flake-update — a new list rolls out on the next qbt restart).
  # ngosang/trackerslist trackers_best.txt is ~20 curated all-UDP trackers — the sweet
  # spot for peer reach. More is net-negative (dead/duplicate trackers + announce/DNS/TLS
  # overhead; DHT/PEX cover the rest). Joined into qBittorrent's AdditionalTrackers value
  # (one URL per line — QSettings serialises the newlines as `\n` in qBittorrent.conf).
  bestTrackers =
    lib.filter (l: lib.strings.hasInfix "://" l)
    (lib.splitString "\n" (builtins.readFile "${inputs.trackerslist}/trackers_best.txt"));
  additionalTrackers = lib.concatStringsSep "\\n" bestTrackers;

  # ── qBittorrent.conf: MERGE the Nix-managed keys; do NOT clobber the whole file ──
  # The upstream services.qbittorrent module installs a freshly-generated qBittorrent.conf
  # (containing ONLY the serverConfig keys) over the real one on EVERY service start. That
  # reset every WebUI-set preference to qBittorrent's defaults on each boot/restart — the
  # "settings don't persist after a reboot" bug. (Torrent state survived because it lives in
  # a different dir, BT_backup/, that the install never touched.)
  #
  # So we DON'T set serverConfig. Instead managedConf below is the single source of truth for
  # the keys Nix owns, and the merge pre-start (qbtMergeConfig) splices just those keys into
  # the guest's persisted conf — leaving every other (user/WebUI-set) key intact. Net:
  #   • user/WebUI settings persist across reboots, and
  #   • the managed keys (WebUI bind/whitelist, save path, nightly tracker list) are still
  #     re-applied on every start, so the tracker refresh keeps working (restartTriggers on
  #     managedConf re-runs the merge whenever a nightly flake bump changes the list).
  #
  # Managed keys (was serverConfig — rationale preserved here):
  #   WebUI\Address=*                       bind all guest ifaces; reached via pfSense from
  #                                         servarr (and qbt.ablz.au through servarr's nginx).
  #   WebUI\AuthSubnetWhitelist[Enabled]    no-creds path for the LAN subnet qbt sees (pfSense
  #                                         ROUTES LAN→VLAN20, no NAT → real .101); pfSense
  #                                         permits ONLY servarr→8080, so humans are LAN-only.
  #   Session\DefaultSavePath=/downloads/   qbt writes ONLY into the virtiofs scratch; *arr
  #                                         hardlink completed files out of there. Never /data.
  #   Session\Add[itional]Trackers          auto-append the public list to NEW torrents.
  # Format = qBittorrent's own INI: backslash-nested keys, lowercase bools, AdditionalTrackers
  # one line with `\n`-escaped URLs (QSettings unescapes them back to newlines on read).
  managedConf = pkgs.writeText "qBittorrent-managed.conf" ''
    [BitTorrent]
    Session\AddTrackersEnabled=true
    Session\AdditionalTrackers=${additionalTrackers}
    Session\DefaultSavePath=/downloads/

    [Preferences]
    WebUI\Address=*
    WebUI\AuthSubnetWhitelistEnabled=true
    WebUI\AuthSubnetWhitelist=192.168.1.0/24
  '';

  # Pre-start, run before qbittorrent-nox as the service user while the conf is quiescent:
  #   • fresh state volume (no conf) → seed exactly the managed keys;
  #   • existing conf → crudini-merge the managed keys in, preserving every other key, then
  #     normalise crudini's `k = v` back to qBittorrent's own `k=v`.
  # Merge failure is deliberately NON-fatal: fall through and start with the existing conf
  # (managed keys persist from the previous merge) rather than brick a live torrent box.
  qbtMergeConfig = pkgs.writeShellScript "qbt-merge-config" ''
    set -u
    conf="/var/lib/qBittorrent/qBittorrent/config/qBittorrent.conf"
    if [ ! -e "$conf" ]; then
      ${pkgs.coreutils}/bin/install -Dm600 ${managedConf} "$conf"
      exit 0
    fi
    if ${pkgs.crudini}/bin/crudini --merge --inplace "$conf" < ${managedConf}; then
      ${pkgs.gnused}/bin/sed -i -E 's/^([^=]*[^= ]) = /\1=/' "$conf"
      ${pkgs.coreutils}/bin/chmod 600 "$conf"
    else
      echo "qbt-merge-config: crudini merge failed; starting with existing conf" >&2
    fi
  '';
in {
  imports = [inputs.microvm.nixosModules.host];

  # Host L2 conduit: a bridge joining servarr's VLAN-20 uplink + the qbt tap.
  # servarr itself takes NO IP here — it only transports qbt's frames to tower
  # br0.20 → eth0.20 → switch (VLAN 20 tagged) → pfSense. servarr stays on the
  # main LAN (.4) via its primary NIC; this bridge is a pure cage conduit.
  systemd.network.enable = true;
  # NetworkManager owns servarr's real connectivity (the LAN NIC / .4) and has its
  # own NetworkManager-wait-online. networkd here manages ONLY the DMZ cage, which is
  # intentionally IP-less and never reaches "online" — so systemd-networkd-wait-online
  # would always time out (→ host `degraded`). Per its own docs, disable it when a
  # different service manages the system's connection. network-online.target is still
  # satisfied via NetworkManager-wait-online.
  systemd.network.wait-online.enable = false;
  systemd.network.netdevs."br-dmz".netdevConfig = {
    Name = "br-dmz";
    Kind = "bridge";
  };
  systemd.network.networks."40-br-dmz" = {
    matchConfig.Name = "br-dmz";
    networkConfig.ConfigureWithoutCarrier = true;
    linkConfig.RequiredForOnline = false;
  };
  systemd.network.networks."41-dmz-uplink" = {
    matchConfig.Name = dmzUplink; # the VLAN-20 vNIC — bridge member, no IP
    networkConfig.Bridge = "br-dmz";
    linkConfig.RequiredForOnline = false;
  };
  systemd.network.networks."42-dmz-tap" = {
    matchConfig.Name = "vm-qbt"; # the tap microvm.nix creates from the id below
    networkConfig.Bridge = "br-dmz";
    linkConfig.RequiredForOnline = false;
  };

  # The base profile uses NetworkManager, which owns the LAN NIC (DHCP → servarr's
  # .4). Keep NM OFF the DMZ interfaces — systemd-networkd owns br-dmz + the VLAN-20
  # uplink + the qbt tap. Without this NM would also DHCP the VLAN-20 vNIC (pulling a
  # 192.168.20.x onto servarr, which must stay a pure L2 conduit) and fight the bridge.
  networking.networkmanager.unmanaged = [
    "interface-name:${dmzUplink}"
    "interface-name:br-dmz"
    "interface-name:vm-qbt"
  ];

  microvm.vms.qbt.config = {
    imports = [inputs.microvm.nixosModules.microvm];

    networking.hostName = "qbt";
    system.stateVersion = "25.05";

    microvm = {
      hypervisor = "cloud-hypervisor";
      vcpu = 2;
      mem = 768;
      vsock.cid = 20; # systemd-notify over vsock → servarr knows when qbt is up
      # NFS-backed /downloads share rejects ACLs/xattrs → strip --posix-acl/--xattr.
      virtiofsd.package = virtiofsdNoXattr;
      shares = [
        {
          # RO /nix/store from the host — no per-VM store duplication (tiny RAM).
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }
        {
          # The ONLY data window: a scratch subdir of the library fs. NEVER the
          # library, NEVER the rest of /data. servarr hardlinks OUT of here.
          source = "/media/data/Media/Temp";
          mountPoint = "/downloads";
          tag = "downloads";
          proto = "virtiofs";
        }
      ];
      volumes = [
        {
          # Persistent qbt state (config, session, .fastresume). The mountPoint MUST
          # match services.qbittorrent.profileDir — nixpkgs default `/var/lib/qBittorrent`
          # (capital Q + B). A lowercase `/var/lib/qbittorrent` silently mounts the volume
          # on a path qBittorrent never writes, so its state lands on the EPHEMERAL microVM
          # root and is wiped on every restart/reboot (the lost-torrents bug; fixed
          # 2026-06-23 — the volume had been mounted one case off and sat empty).
          mountPoint = "/var/lib/qBittorrent";
          image = "qbt-state.img"; # lands under /var/lib/microvms/qbt/ on servarr
          size = 1024; # MiB
        }
      ];
      interfaces = [
        {
          type = "tap";
          id = "vm-qbt";
          mac = "02:00:00:00:20:02"; # locally-administered; corresponds to .20.2
        }
      ];
    };

    # VLAN-20 address only. Egress restriction / kill-switch / default-deny all
    # live at pfSense — the guest just needs IP + gateway + DNS-via-pfSense.
    systemd.network.enable = true;
    systemd.network.networks."10-eth" = {
      matchConfig.Type = "ether";
      address = ["192.168.20.2/24"];
      routes = [{Gateway = "192.168.20.1";}];
      networkConfig.DNS = "192.168.20.1";
    };

    # qBittorrent headless. WebUI 8080 (only servarr may reach it, per the pfSense
    # inbound exception). Listen 45726 = the reused AirVPN forward. Categories
    # radarr / tv-sonarr / sonarr / prowlarr (= the old deluge labels) are created
    # at migration so the *arr download-client config maps 1:1.
    services.qbittorrent = {
      enable = true;
      # Run as gid 100 (`users`) = the group that owns the NFS scratch dir
      # (/media/data/Media/Temp is 99:100, mode 2775/setgid). virtiofs passes the
      # guest's egid through, so this lets qbt actually WRITE downloads (else EACCES).
      group = "users";
      webuiPort = 8080;
      torrentingPort = 45726;
      # Open 8080 (WebUI) + 45726 (torrent) on the GUEST firewall. pfSense is still the
      # real boundary (default-deny egress → AirVPN only; single inbound servarr→8080; the
      # AirVPN forward → 45726). The guest firewall just must not DROP those allowed flows —
      # with openFirewall=false it silently blocked the WebUI (HTTP 000) and inbound peers.
      openFirewall = true;
      # serverConfig is intentionally NOT set: the module would install it over
      # qBittorrent.conf on every start, wiping all WebUI-set prefs. The managed keys are
      # MERGED in via the ExecStartPre override below instead — see managedConf in the let.
    };

    systemd.services.qbittorrent = {
      # Re-apply ONLY the managed keys via the merge pre-start (managedConf / qbtMergeConfig
      # in the let above) instead of the module's whole-file clobber, so WebUI settings
      # persist across reboots. mkForce wins over any module-provided ExecStartPre.
      # restartTriggers re-runs the merge (→ fresh tracker list) whenever managedConf changes.
      restartTriggers = [managedConf];
      serviceConfig.ExecStartPre = lib.mkForce "${qbtMergeConfig}";

      # Downloads land on the NFS scratch, where the backend squashes qbt's uid to 99
      # (nobody); qbt re-opens its OWN files for writing via gid 100 (group), so they
      # must be GROUP-WRITABLE. Default umask 022 → 0664... → 0644 (group read-only) →
      # EACCES on file_open. umask 002 → 0664 → qbt writes; *arr read/hardlink via group.
      serviceConfig.UMask = "0002";
    };

    # No fleet trust, no tailscale, nothing else. This box is disposable.
    networking.firewall.enable = lib.mkDefault true;
    networking.firewall.allowedUDPPorts = [45726]; # uTP/DHT inbound (TCP opened by openFirewall)
  };
}
