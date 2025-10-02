{pkgs, ...}: {
  services.printing.enable = true;
  services.printing.drivers = [pkgs.cups-brother-mfcl2750dw];

  # Disable CUPS Browse-d as everything uses IPP and it causes random hangs on shutdown/reboot
  services.printing.browsed.enable = false;

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Ok so the above will ensure that the printer is available on the network if we are inside the lan.
  # THe below will add the printer if we are connected VIA Tailscale. The subnet router will route the address.
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
}
