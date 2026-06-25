{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../common/desktop.nix # Includes Printing, Fonts, Spotify
    ../common/realtime-audio.nix # Moonlight audio-thread rtprio (anti-stutter)
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
      # Roaming workstation, not a service host: let tailscaled manage netfilter
      # (blanket-accept the tailnet) so sunshine/vnc/etc. stay reachable without
      # per-port pinholes. Servers default to "off" (nixos-fw gates the tailnet).
      netfilterMode = "on";
    };
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = false;
      trim = true;
    };

    # Magazine PDF->EPUB conversion "last mile". Triggered by doc2's
    # gwm-archiver after a new download (WOL + SSH), weekly RTC-wake safety
    # net. See docs/wiki/services/magazine-epub-pipeline.md.
    services.marker-convert.enable = true;
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

    # Use our plain 1h-TTL ssh-agent (homelab.ssh.localAgent) instead of
    # GNOME's session-long gcr-ssh-agent. Only the SSH agent component is
    # disabled — gnome-keyring's secret service is unaffected.
    gnome.gcr-ssh-agent.enable = false;

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
  systemd.services = {
    "getty@tty1".enable = false;
    "autovt@tty1".enable = false;
    "gnome-remote-desktop".wantedBy = ["graphical.target"];
  };
  security.rtkit.enable = true;

  users.users.abl030 = {
    extraGroups = ["libvirtd" "vboxusers" "dialout"];
  };

  # forgejo#2 Phase 4: passwordless `nixos-rebuild` REMOVED. It was a passwordless
  # root pivot (rebuild → a config with a setuid shell), the same class we closed
  # on doc2/igpu. This is an interactive workstation — abl030 has a password, so
  # deploy/admin is interactive `sudo` (you're at the keyboard), and fleet-wide
  # changes also converge via the nightly nixos-upgrade timer (runs as root, no
  # sudo). A popped abl030/service can no longer rebuild-to-root without the
  # password. See docs/wiki/infrastructure/fleet-deploy-and-sibling-lockdown.md.

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    gnome-remote-desktop
    kdiskmark
    # Morrowind via OpenMW (open-source engine reimplementation) + portmod, a
    # CLI mod manager (used to install Tamriel Rebuilt, the mainland expansion).
    # OpenMW ships NO copyrighted assets — the game DATA files come from the
    # Steam copy enabled below. Runtime setup (wizard + TR) is a one-time at-the-
    # keyboard step; see the OpenMW/Tamriel-Rebuilt runbook handed off in chat.
    openmw # engine + openmw-launcher + openmw-wizard + openmw-navmeshtool
    portmod # `portmod openmw merge tamriel-rebuilt` (+ Tamriel_Data) on first run
  ]);

  # Steam — only needed to DOWNLOAD Morrowind's data files (buy the GOTY edition;
  # it bundles Tribunal + Bloodmoon). OpenMW then plays them natively, no Proton
  # at runtime. Unfree is already allowed fleet-wide via profiles/base.nix.
  programs.steam.enable = true;

  programs.firefox.enable = true;

  system.stateVersion = "24.05";
}
