{
  lib,
  config,
  allHosts,
  ...
}: let
  signing = import ../../../nix/fleet-signing.nix {inherit lib;};
  cfg = config.homelab.update.verify;
  etcPath = lib.removePrefix "/etc/" cfg.allowedSignersPath;
in {
  # Trust model and recovery procedures:
  # docs/wiki/infrastructure/signed-fleet-deploys.md
  options.homelab.update.verify = {
    enable = lib.mkEnableOption "signed fleet update verification trust anchor" // {default = true;};

    allowedSignersPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/fleet-update/allowed_signers";
      description = "Path to the OpenSSH allowed_signers file used for fleet update verification.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/etc/" cfg.allowedSignersPath;
        message = "homelab.update.verify.allowedSignersPath must live under /etc";
      }
      {
        assertion = signing.validationErrors allHosts == [];
        message = "fleet signing hosts.nix validation failed: ${lib.concatStringsSep "; " (signing.validationErrors allHosts)}";
      }
    ];

    environment.etc.${etcPath} = {
      text = signing.allowedSignersText allHosts;
      mode = "0644";
    };
  };
}
