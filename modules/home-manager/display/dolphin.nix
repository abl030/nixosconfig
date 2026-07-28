{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.dolphin;
  staleCalligraPopplerPatch = "e9aae90db47ca87d639b8f2b17ec75c1b6093e27";
  calligraForDolphin = pkgs.kdePackages.calligra.overrideAttrs (old: {
    # nixpkgs added this as a Poppler 26.04 backport, then kept applying it
    # after Calligra 26.04.3 incorporated the same change. Keep every other
    # patch and remove only this known-stale one. Track removal in Forgejo #63.
    patches = lib.filter (
      patch: !(lib.hasInfix staleCalligraPopplerPatch (toString patch))
    ) (old.patches or []);
  });
in {
  imports = [
    ./mime.nix
  ];

  options.homelab.dolphin = {
    enable = mkEnableOption "Enable Dolphin File Manager";
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (
          patch: !(lib.hasInfix staleCalligraPopplerPatch (toString patch))
        ) (calligraForDolphin.patches or []);
        message = "The stale Calligra Poppler backport escaped the Forgejo #63 workaround";
      }
    ];

    # 0. Dependencies
    homelab.qt.enable = true; # Ensure kdeglobals/theming is active

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
      calligraForDolphin
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
