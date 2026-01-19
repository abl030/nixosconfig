{
  lib,
  pkgs,
  ...
}: {
  # ---------------------------------------------------------
  # 1. PACKAGES & FONTS
  # ---------------------------------------------------------
  environment.systemPackages = lib.mkOrder 1500 (with pkgs; [
    spotify
    nerd-fonts.sauce-code-pro
  ]);

  # ---------------------------------------------------------
  # 2. PRINTING & AVAHI
  # ---------------------------------------------------------
  services = {
    printing = {
      enable = true;
      drivers = [pkgs.cups-brother-mfcl2750dw];
      # Disable CUPS Browse-d to prevent random hangs on shutdown
      browsed.enable = false;
    };

    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };
  };

  hardware.printers = {
    ensurePrinters = [
      {
        name = "Brother_MFC_L2750DW";
        location = "Home";
        deviceUri = "ipp://192.168.1.21:631/ipp/print";
        model = "brother-MFCL2750DW-cups-en.ppd";
        ppdOptions = {
          PageSize = "A4";
        };
      }
    ];
    ensureDefaultPrinter = "Brother_MFC_L2750DW";
  };

  # ---------------------------------------------------------
  # 3. FIREWALL & NETWORKING
  # ---------------------------------------------------------
  # Spotify Local files
  networking.firewall.allowedTCPPorts = [57621];
  # Google cast
  networking.firewall.allowedUDPPorts = [5353];
}
