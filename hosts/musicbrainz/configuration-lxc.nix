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
    hostName = "musicbrainz";
    useDHCP = false;
    useHostResolvConf = false;
    interfaces.eth0.ipv4.addresses = [
      {
        address = "192.168.1.43";
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

  homelab.services.musicbrainz = {
    enable = true;
    databaseMode = "native";
    databaseDir = "/var/lib/musicbrainz-postgresql";
    dataDir = "/var/lib/musicbrainz";
    mirrorDir = "/var/lib/musicbrainz-mirrors";
  };

  # Direct Proxmox bind mounts are the canary's fail-closed state boundary.
  # Refuse to start either the database or application stack if any expected
  # dataset silently falls back to the LXC root filesystem.
  systemd.services.musicbrainz-storage-verify = {
    description = "Verify MusicBrainz direct ZFS dataset mounts";
    wantedBy = ["multi-user.target"];
    before = ["postgresql.service" "musicbrainz.service"];
    requiredBy = ["postgresql.service" "musicbrainz.service"];
    path = [pkgs.util-linux];
    script = ''
      set -euo pipefail
      for mount in \
        /var/lib/musicbrainz \
        /var/lib/musicbrainz-postgresql \
        /var/lib/musicbrainz-mirrors/solrdata \
        /var/lib/musicbrainz-mirrors/dbdump \
        /var/lib/musicbrainz-mirrors/solrdump \
        /var/lib/musicbrainz-mirrors/lrclib \
        /var/lib/containers
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
