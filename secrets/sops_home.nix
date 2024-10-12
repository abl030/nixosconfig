{ inputs, config, ... }:

let
  username = config.home.username; # Gets the current username
  homeDir = "/home/${username}"; # Constructs the home directory path
in
{
  imports = [
    inputs.sops-nix.homeManagerModules.sops
  ];

  sops = {
    age.keyFile = "${homeDir}/.config/sops/age/keys.txt"; # Use dynamic home directory
    defaultSopsFile = ./secrets.yaml;
    validateSopsFiles = false;

    secrets = {
      "smbpassword" = {
        # Use dynamic username
        path = "${homeDir}/smb_credential"; # Use dynamic home directory
      };
    };
  };
}

