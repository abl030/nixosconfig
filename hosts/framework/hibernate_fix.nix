{pkgs, ...}: {
  # ============================================================================
  # FRAMEWORK AMD / MEDIATEK WIFI SLEEP FIXES
  # ============================================================================
  #
  # Diagnosis:
  # The Mediatek mt7921e WiFi card fails to resume properly (Error -110 ETIMEDOUT),
  # leaving the PCI device in a zombie state. When the system attempts to
  # hibernate (suspend-to-disk) afterwards, the kernel hangs trying to talk
  # to this zombie device, resulting in a black screen and "Image not found".
  #
  # Solution:
  # 1. Kernel Params: Disable ASPM to prevent the hardware link from sleeping too deeply.
  # 2. Service: Force-unload the entire WiFi driver stack before sleep and reload on wake.
  # ============================================================================

  boot.kernelParams = [
    # Prevents the WiFi card from entering deep PCIe power states that it struggles to wake from.
    "mt7921e.disable_aspm=1"

    # Optional: If you still see issues, uncomment this to prevent PCI-E lane power gating
    # "pcie_aspm=off"
  ];

  systemd.services.wifi-hibernate-fix = {
    description = "Unload Mediatek WiFi drivers before sleep to prevent kernel hang";

    # We want this to run for ALL sleep types to ensure a clean state
    wantedBy = [
      "suspend.target"
      "hibernate.target"
      "suspend-then-hibernate.target"
      "hybrid-sleep.target"
    ];

    # It must run BEFORE the system tries to sleep
    before = [
      "systemd-suspend.service"
      "systemd-hibernate.service"
      "systemd-suspend-then-hibernate.service"
      "systemd-hybrid-sleep.service"
    ];

    # Stop this service (which runs ExecStop) when the sleep target is stopped (i.e., on resume)
    partOf = [
      "suspend.target"
      "hibernate.target"
      "suspend-then-hibernate.target"
      "hybrid-sleep.target"
    ];

    unitConfig = {
      # Critical: Run regardless of network status
      DefaultDependencies = "no";
      # Ensure it doesn't get killed midway
      # StopWhenUnneeded = "yes";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutSec = "15s";

      # 1. UNLOAD (ExecStart - runs before sleep)
      # We remove the whole stack: device specific -> common -> library -> mac80211 wrapper
      # 'modprobe -r' handles dependencies, but listing them ensures thoroughness if one is stuck.
      # We ignore errors (-) just in case modules are already unloaded.
      ExecStart = [
        "-${pkgs.kmod}/bin/modprobe -r mt7921e mt7921_common mt76_connac_lib mt76"
        # Small pause to let PCI bus settle after driver detachment
        "${pkgs.coreutils}/bin/sleep 1"
      ];

      # 2. RELOAD (ExecStop - runs on resume)
      # We only need to load the top-level module; kernel handles the rest.
      ExecStop = [
        "${pkgs.kmod}/bin/modprobe mt7921e"
        # Wait a moment for firmware to load before NetworkManager jumps on it
        "${pkgs.coreutils}/bin/sleep 2"
      ];
    };
  };
}
