{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/services/podcast.nix
    # Stacks managed via hosts.nix containerStacks
  ];

  homelab = {
    mounts = {
      nfsLocal.enable = true;
      nfsLocal.readOnly = false; # Safety during podman testing
      external.enable = true;
      fuse.enable = true;
    };
    # Base.nix enables ssh=true/secure=true.
    # We override secure to false here matching your previous config.
    ssh.secure = false;

    # Base.nix enables tailscale=true.

    pve.enable = true;

    # Base.nix enables update=true.
    # We just add specific timing/dates here.
    update = {
      updateDates = "03:00";
      gcDates = "03:30";
      rebootOnKernelUpdate = true;
    };

    containers = {
      enable = true;
    };

    cache = {
      enable = true;
      mirrorHost = "nix-mirror.ablz.au";
      localHost = "nixcache.ablz.au";
      nixServeSecretKeyFile = "/var/lib/nixcache/secret.key";
    };

    # Override profile from "internal" (base default) to "server"
    nixCaches.profile = "server";

    ci.rollingFlakeUpdate = {
      enable = true;
      repoDir = "/home/abl030/nixosconfig";
    };
    services.githubRunner = {
      enable = true;
      repoUrl = "https://github.com/abl030/nixosconfig";
      tokenFile = "/var/lib/github-runner/registration-token";
      runnerName = "proxmox-bastion";
    };
  };

  # Base.nix enables NetworkManager.
  # We just set interface specifics here.
  networking.interfaces.ens18.mtu = 1400;
  networking.firewall.enable = true;

  # VM Specifics
  services.qemuGuest.enable = true;

  # Workloads
  virtualisation.docker = {
    enable = false;
    liveRestore = false;
  };

  # ADD ONLY HOST SPECIFIC GROUPS
  users.users.abl030 = {
    extraGroups = ["libvirtd" "vboxusers"];
  };

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    butane
  ]);

  security.sudo.extraRules = lib.mkAfter [
    {
      users = ["abl030"];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/current-system/sw/bin/systemctl";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/current-system/sw/bin/journalctl";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
  };

  system.stateVersion = "24.05";
}
