{
  config,
  lib,
  allHosts,
  ...
}: let
  cfg = config.homelab.ssh;
in {
  options.homelab.ssh = {
    enable = lib.mkEnableOption "SSH configuration";
  };

  config = lib.mkIf cfg.enable {
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      # 1. Dynamic Host Configuration (Config File)
      matchBlocks = let
        generatedHosts =
          lib.mapAttrs' (_: hostConfig: {
            name = hostConfig.sshAlias;
            value = {
              inherit (hostConfig) hostname user;
            };
          })
          allHosts;
      in
        generatedHosts
        // {
          "*" = {
            forwardAgent = true;
            setEnv = {TERM = "xterm-256color";};
            forwardX11 = false;
            forwardX11Trusted = false;
          };
        };

      # 2. Dynamic Host Trust (Known Hosts)
      # Iterate over all hosts, check if they have a publicKey, and add them to known_hosts.
      knownHosts = let
        hostsWithKeys = lib.filterAttrs (_: host: host ? publicKey) allHosts;
      in
        lib.mapAttrs (name: host: {
          hostNames = [host.hostname host.sshAlias];
          publicKey = host.publicKey;
        })
        hostsWithKeys;
    };
  };
}
