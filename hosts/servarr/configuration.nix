# servarr — dedicated NixOS VM on tower for the *arr stack (Radarr / Sonarr /
# Prowlarr), replacing the legacy Ubuntu `genericvm` at 192.168.1.4.
#
# The torrent client (qBittorrent) is deliberately NOT here: it runs in an
# isolated `microvm.nix` guest on its own VLAN (Torrent_DMZ / VLAN 20), VPN-only,
# default-deny to the fleet, with a hardlink/virtiofs scratch handoff. Full design
# + build/cutover checklist: Forgejo issue #1.
#
# STATUS: scaffold. Not yet deployed. `hardware-configuration.nix` is a placeholder
# (generated for real at install via nixos-anywhere); the host needs its sops scope
# + fleet-wide secret re-key once it has a host key (issue #1, steps 3–5).
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
  # Migration drops each app's config.xml + *.db into /var/lib/<app> at install (issue
  # #1 step 5) — set BindAddress=127.0.0.1 in each config.xml (tailscale0 is a trusted
  # firewall interface, so a 0.0.0.0 bind would be tailnet-reachable). Download clients
  # carried over: the qbt microVM (qbt.ablz.au) + the remote NZBGet @ 192.168.1.17:6789.
  # Prowlarr keeps syncing to Readarr @ tower 192.168.1.2:8787.

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
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
    };
  };

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
