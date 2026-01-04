{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../services/mounts/nfs.nix
    ../common/desktop.nix # Includes Printing, Fonts, Spotify
    inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    ../framework/sleep-then-hibernate.nix
    ../services/system/remote_desktop_nosleep.nix
  ];

  homelab = {
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
      wakeOnUpdate = false;
      rebootOnKernelUpdate = false;
    };
  };

  boot = {
    extraModprobeConfig = ''
      options cfg80211 ieee80211_regdom="AU"
    '';
    kernelPackages = pkgs.linuxPackages_latest;
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
  };

  services = {
    fwupd = {
      enable = true;
      extraRemotes = ["lvfs-testing"];
    };
    xserver = {
      enable = true;
      xkb.layout = "us";
    };
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;

    # Audio
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    openssh.enable = true;
  };

  hardware.wirelessRegulatoryDatabase = true;
  hardware.graphics.enable = true;

  networking.networkmanager.enable = true;

  # FIX: Prevent system hangs during rebuild/shutdown
  systemd.services = {
    # 1. Disable the "Wait for Online" check. This prevents the rebuild from hanging
    #    indefinitely if Tailscale interferes with connectivity checks.
    NetworkManager-wait-online.enable = false;

    # 2. Force Tailscale to stop in 3 seconds.
    #    This breaks the deadlock where Tailscale waits for network, but network waits for Tailscale.
    tailscaled.serviceConfig.TimeoutStopSec = 3;

    # 3. Optimize Polkit cleanup to prevent D-Bus timeouts during switch
    polkit.serviceConfig.TimeoutStopSec = 5;
  };

  security.rtkit.enable = true;

  users.users.abl030 = {
    extraGroups = ["libvertd" "dialout"];
  };

  environment.systemPackages = with pkgs; [
    gh
    gnome-remote-desktop
    dmidecode
    fprintd
  ];

  programs.firefox.enable = true;

  system.stateVersion = "24.05";
}
