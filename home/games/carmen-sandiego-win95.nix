{pkgs, ...}: let
  wordDetectiveInstaller = ./lutris/carmen-sandiego-word-detective.yaml;
  greatChaseInstaller = ./lutris/carmen-sandiego-great-chase-through-time.yaml;

  wordDetectiveSetup = pkgs.writeShellApplication {
    name = "carmen-word-detective-setup";
    runtimeInputs = [pkgs.lutris];
    text = ''
      exec lutris --install ${wordDetectiveInstaller} "$@"
    '';
  };

  greatChaseSetup = pkgs.writeShellApplication {
    name = "carmen-great-chase-setup";
    runtimeInputs = [pkgs.lutris];
    text = ''
      exec lutris --install ${greatChaseInstaller} "$@"
    '';
  };
in {
  home.packages = [
    pkgs.lutris
    wordDetectiveSetup
    greatChaseSetup
  ];

  # Keep the installers available for inspection and manual re-runs as well as
  # behind the setup commands; Lutris does not need to scan this directory.
  home.file = {
    ".local/share/lutris/installers/carmen-sandiego-word-detective.yaml".source =
      wordDetectiveInstaller;
    ".local/share/lutris/installers/carmen-sandiego-great-chase-through-time.yaml".source =
      greatChaseInstaller;
  };

  xdg.desktopEntries = {
    carmen-word-detective-setup = {
      name = "Set up Carmen Sandiego: Word Detective";
      genericName = "Windows 95 game setup";
      comment = "Install Carmen Sandiego: Word Detective in Lutris";
      exec = "carmen-word-detective-setup";
      terminal = false;
      icon = "net.lutris.Lutris";
      categories = ["Game"];
    };

    carmen-great-chase-setup = {
      name = "Set up Carmen Sandiego's Great Chase Through Time";
      genericName = "Windows 95 game setup";
      comment = "Install Carmen Sandiego's Great Chase Through Time in Lutris";
      exec = "carmen-great-chase-setup";
      terminal = false;
      icon = "net.lutris.Lutris";
      categories = ["Game" "AdventureGame"];
    };
  };
}
