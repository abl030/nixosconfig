{
  lib,
  modulesPath,
  pkgs,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  proxmoxLXC = {
    privileged = false;
    manageNetwork = true;
    manageHostName = true;
  };
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  services.fstrim.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;

  networking = {
    hostName = "discogs";
    useDHCP = false;
    useHostResolvConf = false;
    interfaces.eth0.ipv4.addresses = [
      {
        address = "192.168.1.44";
        prefixLength = 24;
      }
    ];
    defaultGateway = "192.168.1.1";
    nameservers = ["192.168.1.1"];
    firewall.enable = true;
    firewall.allowedTCPPorts = [22];
  };

  services.openssh.enable = true;
  system.autoUpgrade.enable = lib.mkForce false;
  homelab.gotify.enable = false;
  homelab.monitoring.deployOperatorApiKey = false;
  homelab.update = {
    enable = false;
    wakeOnUpdate = false;
    trim = lib.mkForce false;
    pushDeploy.enable = true;
  };
  homelab.tailscale.enable = false;

  homelab = {
    services.discogs = {
      enable = true;
      databaseMode = "native";
      databaseDir = "/var/lib/discogs-postgresql";
      mirrorDir = "/var/lib/discogs-mirror";
      publish = true;
      importCoordinator = "remote";
    };
  };

  # The disruptive monthly import is initiated from doc2 only after
  # Cratedigger has entered its durable discogs-import hold. Permit exactly
  # that fixed systemd action to the ordinary fleet SSH user.
  security.sudo.extraRules = [
    {
      users = ["discogs-import-coordinator"];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl start discogs-import.service";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  # doc2's host key is accepted by a dedicated principal through one forced
  # command. The normal operator account and fleet keys cannot use this sudo
  # boundary to start the destructive importer outside Cratedigger's hold.
  users.groups.discogs-import-coordinator = {};
  users.users.discogs-import-coordinator = {
    isSystemUser = true;
    group = "discogs-import-coordinator";
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      ''restrict,from="192.168.1.35",command="/run/wrappers/bin/sudo --non-interactive /run/current-system/sw/bin/systemctl start discogs-import.service" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPv9MVIv00FafaGR/mPE3nW565bycshuwxlh3vhT+bZp doc2-discogs-import''
    ];
  };

  systemd.services.discogs-storage-verify = {
    description = "Verify Discogs direct ZFS dataset mounts";
    wantedBy = ["multi-user.target"];
    before = ["postgresql.service" "discogs-api.service" "discogs-import.service"];
    requiredBy = ["postgresql.service" "discogs-api.service" "discogs-import.service"];
    path = [pkgs.util-linux];
    script = ''
      set -euo pipefail
      for mount in \
        /var/lib/discogs-postgresql \
        /var/lib/discogs-mirror/dumps
      do
        actual=$(findmnt -n -o TARGET --target "$mount")
        if [ "$actual" != "$mount" ]; then
          echo "ERROR: $mount is not an exact mount (resolved to $actual)" >&2
          exit 1
        fi
      done
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  system.stateVersion = "26.11";
}
