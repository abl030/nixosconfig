# servarr — dedicated NixOS VM on tower for the *arr stack (Radarr / Sonarr /
# Prowlarr), which replaced (and reclaimed the 192.168.1.4 LAN IP of) the legacy
# Ubuntu `genericvm` / `Downloader2`.
#
# The torrent client (qBittorrent) is deliberately NOT here: it runs in an
# isolated `microvm.nix` guest on its own VLAN (Torrent_DMZ / VLAN 20), VPN-only,
# default-deny to the fleet, with a hardlink/virtiofs scratch handoff. Full design
# + build/cutover checklist: Forgejo issue #1.
#
# LIVE since 2026-06-22; moved to its final 192.168.1.4 on 2026-06-23 (pfSense DHCP
# static reservation, MAC 52:54:00:5e:a1:04). Unlike the downloader it reclaimed .4
# from, servarr egresses via the normal WAN — it is deliberately NOT in pfSense's
# MV_VPN_IPS alias (the VPN boundary is the qbt DMZ guest only). Architecture, the
# qbt cage, and cutover history: docs/wiki/services/servarr-and-qbt-cage.md (#1).
{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware-configuration.nix
    ./qbt-microvm.nix
  ];

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    # *arr apps watch large library trees.
    kernel.sysctl."fs.inotify.max_user_watches" = 2097152;
  };

  networking.hostName = "servarr";

  # --- Media library (tower array over NFS), shared by the *arr stack -----------
  # Same export the legacy box used. Hardlinks work within this single NFS fs:
  # downloads land in a subdir (…/Media/Temp) and import hardlinks into the library
  # (…/Media/Movies, …/Media/TV Shows) on the same fs. The qbt microVM gets ONLY a
  # scratch subdir of this fs via virtiofs (never the library itself) — see issue #1.
  fileSystems."/media/data" = {
    device = "192.168.1.2:/mnt/user/data";
    fsType = "nfs";
    options = ["rw" "noatime" "vers=4.2" "hard" "_netdev" "x-systemd.automount" "x-systemd.mount-timeout=30"];
  };

  # The media group + the *arr stack (Radarr/Sonarr/Prowlarr) + the qbt reverse-proxy
  # all live in homelab.services.servarr (modules/nixos/services/servarr.nix): bound to
  # loopback behind nginx/localProxy, reached LAN-wide ONLY via *.ablz.au, never by IP.
  # The migrated config.xml + *.db live in /var/lib/<app> (each config.xml binds
  # 127.0.0.1: tailscale0 is a trusted firewall interface, so a 0.0.0.0 bind would be
  # tailnet-reachable). Download clients: the qbt microVM (qbt.ablz.au) + the remote
  # NZBGet @ 192.168.1.17:6789. Prowlarr syncs to Readarr @ tower 192.168.1.2:8787.
  # Migration mechanics (data-dir paths, DynamicUser quirks) are in the wiki doc above.

  homelab = {
    services.servarr.enable = true;
    ssh.enable = true; # fleet member: key-only, trusts the doc1 bastion key
    # NOT a tailnet node (overrides base's mkDefault). servarr is a VM on tower,
    # and tower is the sole subnet router advertising the LAN to the tailnet, so
    # remote access reaches servarr's LAN IP via that route — no node needed.
    # *.ablz.au is served by nginx on the LAN IP (localProxy hosts aren't
    # tailscaleOnly) and 80/443 are open on the LAN, so the proxy path is
    # tailnet-independent. Drops the otherwise-failing tailscale-wait.service.
    tailscale.enable = false;
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    # NIGHTLY AUTO-UPGRADE IS OFF (update.enable = false): servarr is RAM-tight (4 GiB;
    # tower is too full to grant more) and OOM-kills itself doing a local nixos-rebuild
    # — the eval + closure-copy page-cache blow past 4 GiB and the kernel shoots the qbt
    # microVM (2026-06-23 incident). Deploys are instead BUILT ON doc1 and the closure
    # pushed over + activated remotely (break-glass; the locked host activates via the
    # qemu-guest-agent). Disabling the whole module (rather than just system.autoUpgrade)
    # avoids an orphan/malformed nixos-upgrade.timer. GC + fstrim are kept directly below
    # so the 64 GiB disk doesn't fill. Re-enable only if servarr gets materially more RAM.
    update.enable = false;
  };

  # Housekeeping that homelab.update would have provided (it's off, above) — neither rebuilds.
  nix.gc = {
    automatic = true;
    dates = "02:00";
    options = "--delete-older-than 3d";
  };
  services.fstrim.enable = true;

  services.qemuGuest.enable = true;

  # sops: derive the age key from the host SSH key (fleet-standard pattern).
  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };
  system.activationScripts.sopsAgeKey = {
    deps = ["specialfs"];
    text = ''
      if [ ! -s /var/lib/sops-nix/key.txt ]; then
        install -d -m 0700 /var/lib/sops-nix
        ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > /var/lib/sops-nix/key.txt
        chmod 600 /var/lib/sops-nix/key.txt
      fi
    '';
  };
  system.activationScripts.setupSecrets.deps = lib.mkBefore ["sopsAgeKey"];

  system.stateVersion = "25.05";
}
