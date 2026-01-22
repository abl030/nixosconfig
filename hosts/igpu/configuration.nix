{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    kernelPackages = pkgs.linuxPackages_latest;
    kernel.sysctl = {
      "fs.inotify.max_user_watches" = 2097152;
    };
    kernelParams = ["cgroup_disable=hugetlb"];
  };

  homelab = {
    mounts = {
      nfsLocal.enable = true;
      fuse.enable = true;
    };
    containers = {
      enable = true;
      autoUpdate.enable = true;
      cleanup.enable = true;
    };
    ssh = {
      enable = true;
      secure = false;
    };
    tailscale.enable = true;
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
      rebootOnKernelUpdate = true;
    };
  };

  hardware = {
    graphics.enable = true;
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;
  };

  # ADD ONLY HOST SPECIFIC GROUPS
  users.users.abl030 = {
    extraGroups = ["video" "render"];
  };

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    libva-utils
    radeontop
    nvtopPackages.amd
  ]);

  services.qemuGuest.enable = true;

  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };
  system = {
    activationScripts.sopsAgeKey = {
      deps = ["specialfs"];
      text = ''
        if [ ! -s /var/lib/sops-nix/key.txt ]; then
          install -d -m 0700 /var/lib/sops-nix
          ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > /var/lib/sops-nix/key.txt
          chmod 600 /var/lib/sops-nix/key.txt
        fi
      '';
    };
    activationScripts.setupSecrets.deps = lib.mkBefore ["sopsAgeKey"];
    stateVersion = "25.05";
  };

  # Ensure igpu-management starts on rebuild (prod-style).
  systemd.services.igpu-management-stack.restartIfChanged = lib.mkForce true;
  systemd.services.igpu-management-stack.wantedBy = lib.mkForce ["multi-user.target"];

  # Temporary: allow passwordless nixos-rebuild for this clone.
  security.sudo.extraRules = [
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

  # Force /mnt/data read-only on this VM for safety.
  fileSystems."/mnt/data".options = lib.mkForce [
    "x-systemd.requires=network-online.target"
    "x-systemd.after=network-online.target"
    "_netdev"
    "hard"
    "bg"
    "noatime"
    "nfsvers=4.2"
    "ro"
  ];
}
