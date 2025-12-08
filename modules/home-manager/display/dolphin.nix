{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.dolphin;
in {
  imports = [
    ./mime.nix
  ];

  options.homelab.dolphin = {
    enable = mkEnableOption "Enable Dolphin File Manager";
  };

  config = mkIf cfg.enable {
    # 1. Automounting
    services.udiskie = {
      enable = true;
      tray = "auto";
      automount = true;
      notify = true;
    };

    # 2. Packages
    home.packages = with pkgs; [
      kdePackages.dolphin
      kdePackages.dolphin-plugins
      kdePackages.kio-extras
      kdePackages.kio-admin
      kdePackages.ark
      kdePackages.kservice
      kdePackages.kactivitymanagerd
      kdePackages.qtbase

      # Thumbnailers
      kdePackages.kdegraphics-thumbnailers
      kdePackages.ffmpegthumbs
      kdePackages.kdesdk-thumbnailers
      kdePackages.calligra
      shared-mime-info
    ];

    # 3. Inject Preview Settings into the shared kdeglobals
    # This uses the option we defined in qt-theme.nix
    homelab.theme.kdeglobals.extraConfig = ''
      [PreviewSettings]
      # Remote previews: 50 GiB
      MaximumRemoteSize=53687091200
      # Local: effectively unlimited (~100 GiB)
      MaximumSize=107374182400
      # Enable thumbnails
      UseFileThumbnails=true
      EnableRemoteFolderThumbnail=true

      camera=true
      file=true
      fonts=true

      # Plugins list
      Plugins=appimagethumbnail,audiothumbnail,blenderthumbnail,comicbookthumbnail,cursorthumbnail,desktopthumbnail,directorythumbnail,djvuthumbnail,ebookthumbnail,exrthumbnail,fontthumbnail,imagethumbnail,jpegthumbnail,kraorathumbnail,mobithumbnail,opendocumentthumbnail,rawthumbnail,svgthumbnail,textthumbnail,windowsimagethumbnail,windowsexethumbnail,gsthumbnail,ffmpegthumbs,gettextthumbnail
    '';

    # NOTE: dolphinrc is intentionally NOT managed here.
    # It remains mutable so you can save view settings (Sort by Date, View Mode, etc.) from the GUI.
  };
}
