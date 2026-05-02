{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../common/desktop.nix # Includes Printing, Fonts, Spotify
  ];

  # --- INCEPTION MODE: VM Specialisation ---
  specialisation = {
    vm.configuration = {
      system.nixos.tags = ["vm"];
      services.qemuGuest.enable = true;
      system.activationScripts.update-bootloader = ''
        echo "Updating Virtual EFI Bootloader..."
        /nix/var/nix/profiles/system/bin/switch-to-configuration boot
      '';
    };
  };

  homelab = {
    gpu.intel.enable = true;
    mounts.nfs.enable = true;
    mounts.nfsMusic.enable = true; # prom ZFS-direct NFS over LAN
    rdpInhibitor.enable = true;
    ssh = {
      enable = true;
      secure = false;
      inhibitors.enable = true;
    };
    hyprland.enable = false; # Kept available, just disabled
    sunshine.enable = true;
    vnc = {
      enable = true;
      secure = true;
      openFirewall = false;
    };
    tailscale = {
      enable = true;
      tpmOverride = true;
    };
    pve.enable = true;
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = false;
      trim = true;
    };
  };

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelParams = [
      "i915.force_probe=56a6"
      "i915.enable_guc=3"
      "nvme_core.default_ps_max_latency_us=0"
      "video=HDMI-A-2:1920x1080@75e"
      "video=DP-3:2560x1440@144e"
      "video=HDMI-A-3:1920x1080@60e"
    ];
    blacklistedKernelModules = ["xe"];
    initrd.kernelModules = ["i915"];

    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
  };

  hardware = {
    enableRedistributableFirmware = true;
    bluetooth.enable = true;
    graphics.enable = true;
    logitech.wireless = {
      enable = true;
      enableGraphical = true;
    };
  };

  networking = {
    hostName = "epimetheus";
    networkmanager.enable = true;
    firewall = {
      allowedTCPPorts = [3389 3390];
      allowedUDPPorts = [5140];
    };
  };

  services = {
    udev.extraRules = ''
      SUBSYSTEM=="usb", ATTRS{idVendor}=="8087", ATTRS{idProduct}=="0025", ATTR{authorized}="0"
    '';
    fstrim.enable = true;

    # Audio
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    qemuGuest.enable = true;

    # GNOME Desktop + GDM (swapped from Hyprland/SDDM)
    xserver.enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;

    displayManager.autoLogin = {
      enable = true;
      user = "abl030";
    };

    # Hyprland/SDDM xrandr setup (kept for swap-back)
    # xserver.displayManager.setupCommands = ''
    #   ${pkgs.xorg.xrandr}/bin/xrandr --auto
    #   ${pkgs.xorg.xrandr}/bin/xrandr --output HDMI-2 --mode 1920x1080 --rotate right --pos 0x0
    #   ${pkgs.xorg.xrandr}/bin/xrandr --output DP-3 --mode 2560x1440 --primary --pos 1080x0
    #   ${pkgs.xorg.xrandr}/bin/xrandr --output HDMI-3 --mode 1920x1080 --pos 3640x0
    # '';

    # See docs/wiki/services/teamviewer.md
    teamviewer.enable = true;
  };

  virtualisation.docker.enable = false;
  virtualisation.docker.liveRestore = false;

  # GDM auto-login workaround: prevent race with getty on tty1
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  systemd.services."gnome-remote-desktop".wantedBy = ["graphical.target"];
  security.rtkit.enable = true;

  users.users.abl030 = {
    extraGroups = ["libvirtd" "vboxusers" "dialout"];
  };

  # Passwordless nixos-rebuild for the admin user on this workstation.
  # Lets Claude iterate on rebuilds without prompting; scoped to nixos-rebuild
  # only. Other sudo invocations still require a password.
  security.sudo.extraRules = [
    {
      users = ["abl030"];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    gnome-remote-desktop
    kdiskmark
  ]);

  programs.firefox.enable = true;

  system.stateVersion = "24.05";
}
