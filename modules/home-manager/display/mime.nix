{
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.homelab.dolphin.enable {
    # We can revert to the standard Ghostty entry (optional, but cleaner)
    # Or keep your custom one if you prefer the specific flags.
    # For now, let's keep the custom Ghostty one as it's useful,
    # but we DELETE the 'custom-calc' entry entirely.

    xdg.desktopEntries.nvim-ghostty = {
      name = "Neovim (Ghostty)";
      genericName = "Text Editor";
      exec = "ghostty -e nvim %F"; # Note: We can rely on PATH again!
      terminal = false;
      icon = "utilities-terminal";
      categories = ["Utility" "TextEditor"];
      mimeType = ["text/plain" "text/markdown" "text/x-log" "text/csv"];
    };

    xdg.mimeApps = {
      enable = true;

      defaultApplications = {
        "text/html" = ["firefox.desktop"];
        "x-scheme-handler/http" = ["firefox.desktop"];
        "x-scheme-handler/https" = ["firefox.desktop"];
        "application/pdf" = ["firefox.desktop"];

        "inode/directory" = ["org.kde.dolphin.desktop"];

        # Back to the standard file provided by the package
        "text/csv" = ["calc.desktop"];
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = ["calc.desktop"];
        "application/vnd.oasis.opendocument.spreadsheet" = ["calc.desktop"];

        "image/jpeg" = ["org.kde.gwenview.desktop"];
        "image/png" = ["org.kde.gwenview.desktop"];
        "image/svg+xml" = ["org.kde.gwenview.desktop"];
        "image/webp" = ["org.kde.gwenview.desktop"];

        "application/zip" = ["org.kde.ark.desktop"];
        "application/x-tar" = ["org.kde.ark.desktop"];
        "application/x-compressed-tar" = ["org.kde.ark.desktop"];
        "application/x-gzip" = ["org.kde.ark.desktop"];

        "text/plain" = ["nvim-ghostty.desktop"];
        "text/markdown" = ["nvim-ghostty.desktop"];
        "text/x-log" = ["nvim-ghostty.desktop"];
      };

      associations.added = {
        "application/pdf" = ["firefox.desktop"];
        "text/csv" = ["calc.desktop"];
        "text/plain" = ["nvim-ghostty.desktop"];
        "inode/directory" = ["org.kde.dolphin.desktop"];
      };
    };
  };
}
