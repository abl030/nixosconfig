{
  config,
  lib,
  pkgs,
  ...
}: let
  goodixVendorId = "27c6";
  goodixProductId = "609c";

  # -----------------------------------------------------------------------
  # SCRIPT 1: PRE-SLEEP (The Straitjacket)
  # -----------------------------------------------------------------------
  # Masks both Service AND Socket to prevent GDM from waking fprintd early.
  preSleepScript = pkgs.writeShellScript "goodix-pre-sleep" ''
    export PATH="${lib.makeBinPath [pkgs.systemd pkgs.coreutils pkgs.procps]}"

    echo "Stopping and Masking fprintd (Service + Socket)..."

    # 1. Mask runtime units to prevent activation
    systemctl mask --runtime fprintd.service fprintd.socket

    # 2. Stop the service and socket if running
    systemctl stop fprintd.service fprintd.socket

    # 3. Nuclear cleanup just in case
    pkill -9 fprintd || true
  '';

  # -----------------------------------------------------------------------
  # SCRIPT 2: POST-RESUME (The Reset & Release)
  # -----------------------------------------------------------------------
  postResumeScript = pkgs.writeShellScript "goodix-post-resume" ''
    export PATH="${lib.makeBinPath [pkgs.systemd pkgs.coreutils pkgs.gnugrep pkgs.util-linux]}"

    echo "=== RESUME: RESETTING FINGERPRINT READER ==="

    # 1. Find the device
    DEVICE_PATH=""
    for dev in /sys/bus/usb/devices/*; do
      if [ -e "$dev/idVendor" ] && grep -q "${goodixVendorId}" "$dev/idVendor" 2>/dev/null; then
        DEVICE_PATH="$dev"
        break
      fi
    done

    # 2. Reset the Hardware
    if [ -n "$DEVICE_PATH" ]; then
      echo "Found Goodix at $DEVICE_PATH - Forcing Driver Rebind..."
      DEVICE_NAME=$(basename "$DEVICE_PATH")

      # Unbind/Bind is cleaner for the driver stack than authorized=0
      echo "$DEVICE_NAME" > /sys/bus/usb/drivers/usb/unbind || true
      sleep 1
      echo "$DEVICE_NAME" > /sys/bus/usb/drivers/usb/bind || true
      sleep 1

      # Enforce Power On
      echo "on" > "$DEVICE_PATH/power/control" || true
    else
      echo "WARNING: Device not found! Kernel quirks may have already reset it."
    fi

    # 3. Wait for udev to settle down
    sleep 2

    # 4. Unmask and Start
    echo "Unmasking fprintd..."
    systemctl unmask --runtime fprintd.service fprintd.socket

    echo "Starting fprintd..."
    systemctl start fprintd.socket fprintd.service

    echo "Done."
  '';
in {
  # =======================================================================
  # FIX 1: Kernel Quirks (Keep these!)
  # =======================================================================
  boot.kernelParams = [
    "xhci_hcd.quirks=0x80"
    "usbcore.quirks=${goodixVendorId}:${goodixProductId}:b"
  ];

  # =======================================================================
  # FIX 2: Udev Rules
  # =======================================================================
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="${goodixVendorId}", ATTR{idProduct}=="${goodixProductId}", \
      ATTR{power/control}="on", ATTR{power/autosuspend}="-1", ATTR{power/persist}="1"
  '';

  # =======================================================================
  # FIX 3: The Lifecycle Handler
  # =======================================================================
  systemd.services.goodix-suspend-handler = {
    description = "Goodix Fingerprint Suspend/Resume Handler";

    # Start before sleep, Stop after wake
    before = ["sleep.target" "suspend.target" "hibernate.target" "hybrid-sleep.target"];
    wantedBy = ["sleep.target" "suspend.target" "hibernate.target" "hybrid-sleep.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = preSleepScript;
      ExecStop = postResumeScript;
      TimeoutStopSec = "45"; # Give the reset plenty of time
    };

    # Guarantees ExecStop runs on resume
    unitConfig.StopWhenUnneeded = true;
  };

  # Ensure fprintd doesn't try to auto-start on boot before we are ready
  systemd.services.fprintd = {
    after = ["goodix-suspend-handler.service"];
  };
}
