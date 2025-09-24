# ./home/ssh/ssh.nix
{ config, lib, pkgs, allHosts, hostname, ... }:

let
  cfg = config.homelab.home.ssh;

  # --- Pre-computation and Validation ---
  # 1. Create a list of all host configurations, including their original hostname.
  allHostsWithNames =
    lib.mapAttrsToList (name: value: value // { hostName = name; }) allHosts;

  # 2. Filter for hosts that are valid SSH targets from this machine's perspective.
  validSshTargets = builtins.filter
    (host:
      host.hostName != hostname &&
      # Use the correct, explicit library path for robustness.
      lib.attrsets.hasAttrByPath [ "user" ] host &&
      lib.attrsets.hasAttrByPath [ "jumpAddress" ] host &&
      lib.attrsets.hasAttrByPath [ "sshAlias" ] host
    )
    allHostsWithNames;

  # 3. Sort the valid targets to ensure stable processing order.
  sortedSshTargets =
    lib.sort (a: b: a.hostName < b.hostName) validSshTargets;

  # 4. Pre-compute the full sorted list of *all* hostnames for stable IP assignment.
  # This is done once to avoid redundant work inside the generator.
  fullSortedHostNames =
    lib.sort builtins.lessThan (lib.attrNames allHosts);

  # 5. Check for duplicate sshAlias values to prevent silent configuration overwrites.
  aliases = map (h: h.sshAlias) sortedSshTargets;
  uniqueAliases = lib.lists.unique aliases;
  dupes = lib.lists.subtractLists aliases uniqueAliases;

  # --- Small helper: find index of a name in the list without relying on lib.lists.* ---
  indexOf = name: names:
    let
      len = builtins.length names;
      go = i:
        if i >= len then null
        else if builtins.elemAt names i == name then i
        else go (i + 1);
    in
    go 0;
in
{
  options.homelab.home.ssh.enable = lib.mkEnableOption "Enable homelab SSH client config";

  config = lib.mkIf cfg.enable {
    # --- THE KEY CORRECTION IS HERE ---
    # Use a conventional assertion instead of wrapping programs.ssh with mkIf/mkMerge.
    assertions = [{
      assertion = dupes == [ ];
      message = "Duplicate sshAlias values detected in flake.nix hosts: ${toString dupes}";
    }];

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      matchBlocks =
        {
          # 6. A more robust and secure global default block.
          "*" = {
            # Sane defaults for connection stability and security.
            serverAliveInterval = 30;
            serverAliveCountMax = 3;
            compression = false; # Often unnecessary on modern networks
            hashKnownHosts = true;

            # Keep your core settings.
            forwardX11 = true;
            forwardX11Trusted = false; # More secure default; enable per-host if needed.
            setEnv = {
              TERM = "xterm-256color";
            };
          };
        }
        // (lib.listToAttrs (map
          (hostConfig:
            # 7. Generate blocks from the clean, sorted list.
            let
              # 8. Guarded IP index calculation.
              idx = indexOf hostConfig.hostName fullSortedHostNames;

              # Fail the build with a clear error message if something is wrong.
              # (Avoid assertMsg brittleness; use explicit if/throw.)
              ipIndex =
                if idx == null
                then builtins.throw "Could not find host '${hostConfig.hostName}' in the master host list for IP generation."
                else idx + 1;
            in
            lib.nameValuePair hostConfig.sshAlias {
              proxyJump = "${hostConfig.user}@${hostConfig.jumpAddress}";
              hostname = "127.0.0.${toString ipIndex}";
              user = hostConfig.user;
              forwardX11 = true;

              # Allow per-host override; default aligns with the global (secure) default.
              forwardX11Trusted = hostConfig.forwardX11Trusted or false;

              # 9. Add support for optional port and identityFile attributes.
              # Home Manager will correctly omit these if they are null.
              port = hostConfig.port or null;
              identityFile = hostConfig.identityFile or null;

              # HM doesn't expose HostKeyAlias directly; inject it via extraOptions.
              extraOptions = {
                HostKeyAlias = hostConfig.sshAlias;
              };
            }
          )
          sortedSshTargets));
    };
  };
}

