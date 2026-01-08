{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../services/mounts/nfs.nix
    ../common/desktop.nix
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

      # CHANGED: Must be true for the laptop to wake up at 01:00
      wakeOnUpdate = true;

      rebootOnKernelUpdate = false;

      # Smart Update Gates
      checkWifi = ["theblackduck"];
      checkAcPower = true;
    };
  };

  boot = {
    extraModprobeConfig = ''
      options cfg80211 ieee80211_regdom="AU"
    '';
    kernelPackages = pkgs.linuxPackages_latest;
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;

    resumeDevice = "/dev/disk/by-uuid/eced9c09-7bfe-4db4-ad4b-54f155dd1b00";

    kernelParams = [
      "amdgpu.sg_display=0"
      "amdgpu.gpu_recovery=1"
      "resume=/dev/disk/by-uuid/eced9c09-7bfe-4db4-ad4b-54f155dd1b00"
      # "rtc_cmos.use_acpi_alarm=1"

      "amdgpu.abmlevel=0" # new
      "iommu=pt" # new - key addition
    ];
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

  systemd.services = {
    NetworkManager-wait-online.enable = pkgs.lib.mkForce false;
    tailscaled.serviceConfig.TimeoutStopSec = pkgs.lib.mkForce 3;
    polkit.serviceConfig.TimeoutStopSec = pkgs.lib.mkForce 5;
  };

  # Fix for fprintd keeping device busy
  systemd.services.fprintd = {
    wantedBy = ["multi-user.target"];
    serviceConfig.Type = "simple";
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

  # =======================================================================
  # FIX: AMDGPU Suspend Crash Prevention (NFS/Tailscale Hang)
  # =======================================================================

  # 1. DEFENSE IN DEPTH: Soft Mounts
  # Ensure the mounts themselves are less likely to hang the kernel
  # even if our service fails.
  fileSystems."/mnt/data".options = [
    "x-systemd.automount"
    "noauto"
    "_netdev"
    "soft"
    "timeo=30"
    "retrans=2" # Fail fast if network is gone
    "noatime"
  ];
  fileSystems."/mnt/appdata".options = [
    "x-systemd.automount"
    "noauto"
    "_netdev"
    "soft"
    "timeo=30"
    "retrans=2"
    "noatime"
  ];

  # 2. THE CIRCUIT BREAKER SERVICE
  systemd.services.nfs-suspend-prepare = {
    description = "Detach NFS and stop Automounts before sleep to prevent GPU crash";

    # We want to run when the system is trying to sleep
    wantedBy = ["suspend.target" "hibernate.target" "hybrid-sleep.target" "suspend-then-hibernate.target"];

    # CRITICAL ORDERING: We must run BEFORE the service that actually
    # tells the kernel to sleep.
    before = [
      "systemd-suspend.service"
      "systemd-hibernate.service"
      "systemd-hybrid-sleep.service"
      "systemd-suspend-then-hibernate.service"
    ];

    unitConfig = {
      # Run this even if network/other dependencies are already stopping
      DefaultDependencies = "no";
    };

    serviceConfig = {
      Type = "oneshot";
      TimeoutSec = "5s";

      # The '-' prefix tells systemd to ignore errors (e.g. if already unmounted)
      # 1. Stop the automount triggers so nothing can re-mount during suspend
      ExecStart = [
        "-${pkgs.systemd}/bin/systemctl stop mnt-data.automount mnt-appdata.automount"

        # 2. The Hammer: Lazy (-l) and Force (-f) unmount all NFS shares immediately
        "-${pkgs.util-linux}/bin/umount -l -f -a -t nfs,nfs4"
      ];

      # Restart the automounts on resume so they work again
      ExecStop = "-${pkgs.systemd}/bin/systemctl start mnt-data.automount mnt-appdata.automount";
    };
  };

  # FIX: Fingerprint Reader fails on resume
  # 1. Disable USB autosuspend for the Goodix reader (ID 27c6:609c)
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="27c6", ATTR{idProduct}=="609c", ATTR{power/control}="on"
  '';

  # 2. Restart fprintd after resume to pick up the device again
  systemd.services.fprintd-restart-resume = {
    description = "Restart fprintd after resume to fix Goodix connection";
    after = ["suspend.target" "hibernate.target" "hybrid-sleep.target" "suspend-then-hibernate.target"];
    wantedBy = ["suspend.target" "hibernate.target" "hybrid-sleep.target" "suspend-then-hibernate.target"];
    serviceConfig = {
      Type = "oneshot";
      # Wait 2 seconds for USB bus to settle, then restart
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart fprintd.service";
    };
  };
}
