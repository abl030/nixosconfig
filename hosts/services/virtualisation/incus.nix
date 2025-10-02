# Filename: basic-incus-setup.nix
# Replaced the empty pattern {...} with _.
# This indicates the module doesn't use any arguments from the function call, which is cleaner.
_: {
  # Group all virtualisation options under a single attribute set.
  # This makes the configuration modular and avoids conflicts with other modules.
  virtualisation = {
    # 1. Enable Incus
    # This will start the incusd daemon and related services.
    incus.enable = true;

    # 2. Enable the Incus Web UI
    incus.ui.enable = true;

    incus.preseed = {
      networks = [
        {
          config = {
            "ipv4.address" = "10.0.100.1/24";
            "ipv4.nat" = "true";
          };
          name = "incusbr0";
          type = "bridge";
        }
      ];
      profiles = [
        {
          devices = {
            eth0 = {
              name = "eth0";
              network = "incusbr0";
              type = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              size = "35GiB";
              type = "disk";
            };
          };
          name = "default";
        }
      ];
      storage_pools = [
        {
          config = {
            source = "/var/lib/incus/storage-pools/default";
          };
          driver = "dir";
          name = "default";
        }
      ];
    };
  };

  networking.nftables.enable = true;

  # User Group for Administration:
  # To manage Incus without `sudo` for every `incus` command, add your
  # user to the "incus-admin" group in your main NixOS configuration:
  users.users.abl030.extraGroups = ["incus-admin"];

  networking.firewall.trustedInterfaces = ["incusbr0"];
}
