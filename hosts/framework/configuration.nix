{
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../common/desktop.nix
    ../common/realtime-audio.nix # Moonlight audio-thread rtprio (anti-stutter)
    inputs.nixos-hardware.nixosModules.framework-13-7040-amd
  ];

  homelab = {
    mounts.nfs = {
      enable = true;
      external = true; # framework is mobile — reach tower over Tailscale
    };
    # Dedicated magazine archive share — READ-ONLY (defense in depth: framework
    # only reads the library, never writes). Tailscale + automount + soft to
    # match its mobile /mnt/data pattern.
    mounts.magazines = {
      enable = true;
      external = true;
      automount = true;
      readOnly = true;
    };
    mounts.nfsMusic.enable = true;
    rdpInhibitor.enable = true;
    ssh = {
      enable = true;
      secure = false;
      inhibitors.enable = true;
    };
    tailscale = {
      enable = true;
      # Roaming workstation, not a service host: let tailscaled manage netfilter
      # (blanket-accept the tailnet). Servers default to "off" (nixos-fw gates).
      netfilterMode = "on";
    };
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

      # Graphical workstation: a nightly rebuild done while logged in returns
      # switch-to-configuration exit 4 (live GNOME --user units can't restart)
      # even though the system switched — don't page for that. See update.nix.
      tolerateUserUnitFailure = true;
    };
    framework = {
      sleepThenHibernate.enable = true;
      hibernateFix.enable = true;
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
      # "iommu=pt" # new - key addition

      # DEBUGGING
      "no_console_suspend" # Keep console alive during suspend for debugging
      "pm_debug_messages" # More PM debugging output
    ];
  };

  # Re-arm the NFS automount triggers after every resume (suspend, hibernate,
  # hybrid sleep, or suspend-then-hibernate) through NixOS's stock power-management
  # resume hook. ExecStop-on-target-stop did not reliably run on wake and left the
  # automount triggers dead.
  powerManagement.resumeCommands = ''
    /run/current-system/systemd/bin/systemctl restart mnt-data.automount mnt-appdata.automount mnt-Music.automount || true
  '';

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

    # Use our plain 1h-TTL ssh-agent (homelab.ssh.localAgent) instead of
    # GNOME's session-long gcr-ssh-agent. Only the SSH agent component is
    # disabled — gnome-keyring's secret service is unaffected.
    gnome.gcr-ssh-agent.enable = false;

    # Opt out of base.nix's #232 idle-stop (StopIdleSessionSec = 55min): it stops
    # ANY idle logind session, so on this GNOME/Wayland desktop it would KILL the
    # whole session after 55min idle and lose every open window. Interactive
    # workstation, not the SSH-hardening target; the screen still locks. See
    # base.nix. (Suspend-then-hibernate usually fires first, but don't rely on it.)
    logind.settings.Login.StopIdleSessionSec = "infinity";

    # Audio
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    openssh.enable = true;

    # See docs/wiki/services/teamviewer.md
    teamviewer.enable = true;
  };

  hardware.wirelessRegulatoryDatabase = true;
  hardware.graphics.enable = true;

  networking.networkmanager.enable = true;
  # systemd-resolved + NM→resolved DNS now come from base.nix (#262); framework
  # was the original host-local fix and is the canonical proof of the pattern.

  systemd = {
    services = {
      # Prevent nixos-rebuild from restarting network services (kills WiFi)
      NetworkManager.restartIfChanged = false;
      wpa_supplicant.restartIfChanged = false;

      NetworkManager-wait-online.enable = pkgs.lib.mkForce false;
      tailscaled.serviceConfig.TimeoutStopSec = pkgs.lib.mkForce 3;
      polkit.serviceConfig.TimeoutStopSec = pkgs.lib.mkForce 5;

      amdgpu-devcoredump = let
        saveAmdgpuDevcoredump = pkgs.writeShellScript "save-amdgpu-devcoredump" ''
          set -euo pipefail

          data="/sys/class/drm/card1/device/devcoredump/data"
          clear="/sys/class/drm/card1/device/devcoredump/clear"
          out_dir="/var/lib/amdgpu-devcoredump"

          if [[ ! -r "$data" ]]; then
            exit 0
          fi

          mkdir -p "$out_dir"
          ts="$(${pkgs.coreutils}/bin/date -u +"%Y%m%dT%H%M%SZ")"
          out="$out_dir/amdgpu-devcoredump-$ts.bin"
          klog="$out_dir/amdgpu-devcoredump-$ts-kernel.log"

          ${pkgs.coreutils}/bin/dd if="$data" of="$out" bs=1M status=none
          ${pkgs.coreutils}/bin/chmod 600 "$out"

          ${pkgs.systemd}/bin/journalctl -k -b --no-pager > "$klog" || true
          ${pkgs.coreutils}/bin/chmod 600 "$klog" || true

          ${pkgs.util-linux}/bin/logger -t amdgpu-devcoredump "Saved devcoredump to $out and kernel log to $klog"

          if [[ -w "$clear" ]]; then
            echo 1 > "$clear"
          fi
        '';
      in {
        description = "Save AMDGPU devcoredump data";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = saveAmdgpuDevcoredump;
        };
      };

      nfs-suspend-prepare = {
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
          TimeoutSec = "30s"; # Increased from 5s - NFS unmount can be slow

          # The '-' prefix tells systemd to ignore errors (e.g. if already unmounted).
          #
          # ORDER MATTERS: tear down the NFS mounts BEFORE stopping the automount
          # triggers. Stopping an automount that still has a live (and possibly
          # stale, over-Tailscale) NFS mount underneath it blocks until the stop
          # times out — that is exactly what stranded /mnt/data on resume. Lazy
          # (-l) + force (-f) unmounting first breaks the stale handles so the
          # subsequent automount stop is instant.
          ExecStart = [
            # 1. The Hammer: lazy + force unmount all NFS shares immediately.
            "-${pkgs.util-linux}/bin/umount -l -f -a -t nfs,nfs4"

            # 2. Stop the now-detached automount triggers so nothing re-mounts
            #    during suspend.
            "-${pkgs.systemd}/bin/systemctl stop mnt-data.automount mnt-appdata.automount mnt-Music.automount"
          ];
        };
      };
    };

    paths.amdgpu-devcoredump = {
      description = "Watch for AMDGPU devcoredump data";
      wantedBy = ["multi-user.target"];
      pathConfig.PathExists = "/sys/class/drm/card1/device/devcoredump/data";
    };
  };

  security.rtkit.enable = true;

  virtualisation.docker.enable = true;

  users.users.abl030 = {
    extraGroups = ["libvertd" "dialout" "docker"];
    # Keep user@.service alive with no sessions so a detached tmux/mosh survives
    # a full disconnect (not just the base.nix #232 55-min idle-stop). Without
    # linger, closing the last connection stops user@.service and kills the
    # scope-escaped server. Interactive host. (Mirrors doc1/epi.)
    linger = true;
  };

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    gh
    gnome-remote-desktop
    dmidecode
    fprintd
    iw # Wi-Fi link diagnostics; kept useful after AX210 swap.
  ]);

  programs.firefox.enable = true;

  # forgejo#2 Phase 4: passwordless `nixos-rebuild` REMOVED — it was a passwordless
  # root pivot (rebuild → setuid-shell config), same class closed on doc2/igpu.
  # This laptop has an interactive password, so deploy/admin is interactive `sudo`
  # when you're using it; fleet-wide changes also converge via the nightly
  # nixos-upgrade timer (root, no sudo). A popped abl030 can no longer
  # rebuild-to-root. See docs/wiki/infrastructure/fleet-deploy-and-sibling-lockdown.md.
  #
  # (2026-06-28: a temporary passwordless-sudo grant lived here during the mt7921e
  # streaming-lag root-cause hunt and was REVERTED once the diagnosis was complete.
  # 2026-07-07: the Intel AX210 swap is live; the stale mt7921e kernel param and
  # Mediatek module reload workaround were retired. Full story:
  # docs/wiki/infrastructure/framework-mt7921e-streaming-lag.md.)

  system.stateVersion = "24.05";

  # =======================================================================
  # FIX: AMDGPU Suspend Crash Prevention (NFS/Tailscale Hang)
  # =======================================================================

  # 1. DEFENSE IN DEPTH: Soft Mounts
  # Append soft-mount semantics to the module's defaults so a dead
  # tailnet path doesn't pin the kernel. The base options
  # (x-systemd.automount, noauto, _netdev, noatime, the tailscale-wait
  # gate, etc.) come from modules/nixos/services/mounts/nfs.nix — only
  # framework-specific additions live here to avoid duplicating the
  # shared list.
  fileSystems."/mnt/data".options = [
    "soft"
    "timeo=30"
    "retrans=2"
  ];
  fileSystems."/mnt/appdata".options = [
    "soft"
    "timeo=30"
    "retrans=2"
  ];

  # 2. THE CIRCUIT BREAKER SERVICE
}
