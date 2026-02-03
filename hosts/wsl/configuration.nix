{
  lib,
  pkgs,
  inputs,
  hostConfig,
  ...
}: {
  imports = [
    inputs.nixos-wsl.nixosModules.default
    ../common/desktop.nix
  ];

  # --- Base.nix Overrides for WSL ---
  # WSL uses its own bootloader logic, conflicting with systemd-boot
  boot.loader.systemd-boot.enable = false;
  # WSL doesn't use standard NetworkManager logic
  networking.networkmanager.enable = false;
  # fstrim is handled by the host OS / WSL engine usually
  services.fstrim.enable = false;

  homelab = {
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = false; # Redundant with service disable, but good for clarity
    };
    ssh.enable = true;
    tailscale.enable = false;
    mounts = {
      nfs = {
        enable = true;
        server = "192.168.1.2"; # Via Windows Tailscale subnet route
        appdata = false;
      };
      drvfs = {
        enable = true;
        drives.z = {
          label = "Z:";
          mountPoint = "/mnt/z";
        };
      };
      opsSync.enable = true;
    };
  };

  # Suppress duplicate filesystem metric warnings for /run/user tmpfs
  services.prometheus.exporters.node.extraFlags = [
    "--collector.filesystem.mount-points-exclude=^/run/user"
  ];

  # 3. Standard WSL Configuration
  wsl.enable = true;
  wsl.defaultUser = hostConfig.user;

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    neovim
    gh
  ]);

  system.stateVersion = "25.05";
}
