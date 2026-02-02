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
    mounts.nfs.enable = true;
    mounts.drvfs = {
      enable = true;
      drives.z = {
        label = "Z:";
        mountPoint = "/mnt/z";
      };
    };
    mounts.opsSync.enable = true;
  };

  # WSL Hyper-V virtual switch + Tailscale encapsulation limits effective MTU.
  # Without this, SSH KEX packets (especially post-quantum ML-KEM) get silently
  # dropped, causing SSH connections to hang during key exchange.
  systemd.services.tailscale-mtu = {
    description = "Set tailscale0 MTU for WSL";
    after = ["tailscaled.service"];
    requires = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iproute2}/bin/ip link set tailscale0 mtu 1000";
    };
  };

  # 3. Standard WSL Configuration
  wsl.enable = true;
  wsl.defaultUser = hostConfig.user;

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    neovim
    gh
  ]);

  system.stateVersion = "25.05";
}
