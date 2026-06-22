# qbt — the isolated qBittorrent microVM (Forgejo #1).
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
  inputs,
  ...
}: let
  # servarr's 2nd vNIC — attached on tower to br0.20 (VLAN 20). Real name depends
  # on the libvirt NIC order; typically the 2nd virtio NIC. Confirm at install.
  dmzUplink = "ens4"; # TODO(install): confirm servarr's VLAN-20 vNIC name
in {
  imports = [inputs.microvm.nixosModules.host];

  # Host L2 conduit: a bridge joining servarr's VLAN-20 uplink + the qbt tap.
  # servarr itself takes NO IP here — it only transports qbt's frames to tower
  # br0.20 → eth0.20 → switch (VLAN 20 tagged) → pfSense. servarr stays on the
  # main LAN (.4) via its primary NIC; this bridge is a pure cage conduit.
  systemd.network.enable = true;
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

  microvm.vms.qbt.config = {
    imports = [inputs.microvm.nixosModules.microvm];

    networking.hostName = "qbt";
    system.stateVersion = "25.05";

    microvm = {
      hypervisor = "cloud-hypervisor";
      vcpu = 2;
      mem = 768;
      vsock.cid = 20; # systemd-notify over vsock → servarr knows when qbt is up
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
          # Persistent qbt state (config, session, .fastresume).
          mountPoint = "/var/lib/qbittorrent";
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
      webuiPort = 8080;
      torrentingPort = 45726;
      openFirewall = false; # exposure governed by pfSense, not the guest firewall
    };

    # No fleet trust, no tailscale, nothing else. This box is disposable.
    networking.firewall.enable = lib.mkDefault true;
  };
}
