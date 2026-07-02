{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.msnHistoryViewer;

  source = pkgs.fetchFromGitHub {
    owner = "bozdoz";
    repo = "msn-history-viewer";
    rev = "24a1344ae3b15828c32a80a960aeeeb00392bd38";
    hash = "sha256-DldCAw7Fy0rvvmhiKD2LGMebDY+/rhjhCvcwtqWX50M=";
  };

  defaultPackage = pkgs.stdenv.mkDerivation {
    pname = "msn-history-viewer";
    version = "2021-01-17";
    src = source;

    offlineCache = pkgs.fetchYarnDeps {
      src = source;
      hash = "sha256-dto9R8qKy+0dBMowAR/ASDHl+QGNTWlo1mKgpe0K2ZM=";
    };

    nativeBuildInputs = [
      pkgs.yarnConfigHook
      pkgs.yarnBuildHook
      pkgs.nodejs
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r index.html build $out/
      runHook postInstall
    '';
  };
in {
  options.homelab.services.msnHistoryViewer = {
    enable = lib.mkEnableOption "static MSN Messenger history viewer";

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "msn.ablz.au";
      description = "FQDN for the MSN history viewer.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Built static MSN history viewer package.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts.${cfg.fqdn} = {
      useACMEHost = "ablz.au";
      extraConfig = ''
        root * ${cfg.package}
        file_server
      '';
    };

    homelab.monitoring = {
      monitors = [
        {
          name = "MSN history viewer";
          url = "https://${cfg.fqdn}/";
        }
      ];
      # Static site: no write path or app log stream; HTTP monitor covers serving.
      deepProbes = [];
      errorPatterns = [];
    };
  };
}
