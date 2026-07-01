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
  #
  # Mounted via the shared SERVER NFS pattern (homelab.mounts.nfsLocal, the module
  # doc2 already uses for this very export) — STATIC + hard + softreval, NEVER an
  # x-systemd.automount. A server must not lazy-unmount: an automount idle-remount
  # strands the virtiofsd handle the qbt cage holds open into /media/data/Media/Temp,
  # which surfaces in the guest as ESTALE ("Stale file handle") and silently ERRORS
  # live torrents. This box used to hand-roll an inline automount mount (the laptop
  # pattern from nfs.nix) and hit exactly that. appdata=false: the only NFS consumer
  # here is the *arr library + qbt scratch. See the NFS-must-be-static gotcha in
  # docs/wiki/services/servarr-and-qbt-cage.md.

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

    # The media library mount — server pattern, static, no automount (see the long
    # rationale above the /media/data comment). mountPoint=/media/data keeps the path
    # the *arr config + qbt virtiofs share + hardlink layout bake in; appdata=false
    # (not needed here); networkdWaitOnline=false because NetworkManager owns this
    # box's LAN and provides network-online — networkd here only runs the IP-less qbt
    # DMZ cage, which never reaches "online" (qbt-microvm.nix disables its wait-online).
    mounts.nfsLocal = {
      enable = true;
      mountPoint = "/media/data";
      appdata = false;
      networkdWaitOnline = false;
    };

    # Belt-and-braces: if /media/data ever does go stale, restart the qbt microVM so
    # virtiofsd re-opens fresh handles instead of the guest silently erroring torrents,
    # and fire the standard NFS-watchdog alert. The static mount above is the real fix;
    # this catches the residual case (e.g. tower NFS server reboot). `unit` is set
    # because the watchdog key can't be "microvm@qbt" (systemd would template-parse it).
    nfsWatchdog.qbt = {
      path = "/media/data/Media/Temp";
      unit = "microvm@qbt.service";
      interval = "10min";
    };

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
    # microVM (2026-06-23 incident). Disabling the whole module (rather than just
    # system.autoUpgrade) avoids an orphan/malformed nixos-upgrade.timer. GC + fstrim are
    # kept directly below so the 64 GiB disk doesn't fill.
    #
    # Deploys instead ride push-deploy (forgejo#10): doc1 builds servarr's closure
    # nightly (populate_cache.sh) and ACTIVATES it here via a root forced-command key
    # only doc1 holds — the host realises the doc1-signed closure from nixcache.ablz.au
    # and switch-to-configuration's it, no local build, no OOM, no sudo path used.
    # See modules/nixos/autoupdate/push-deploy.nix.
    update.enable = false;
    update.pushDeploy.enable = true;
  };

  # servarr is a role="locked" host (base.nix sets wheelNeedsPassword=true for the
  # locked role), but the agent OPERATES this box from the doc1 bastion — restarting
  # the qbt microVM, clearing stale scratch files, managing downloads — none of which
  # should hang on a password the agent can't type. Grant abl030 passwordless sudo
  # here. mkAfter renders LAST and sudoers is last-match, so this wins over the locked
  # role's default. Same escape hatch as hermes; the box is already firewall-caged and
  # only reachable via the bastion key. See CLAUDE.md "MECHANICAL RECIPE / LOCKED-HOST sudo".
  security.sudo.extraRules = lib.mkAfter [
    {
      users = ["abl030"];
      commands = [
        {
          command = "ALL";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

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
