{
  lib,
  pkgs,
  modulesPath,
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

  networking = {
    hostName = "caddy";
    useDHCP = false;
    interfaces.eth0.ipv4.addresses = [
      {
        address = "192.168.1.6";
        prefixLength = 24;
      }
    ];
    defaultGateway = "192.168.1.1";
    nameservers = ["192.168.1.1"];
    useHostResolvConf = lib.mkForce false;
  };

  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  services.fstrim.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;

  # LXC deploy model matches igpu: no in-container rebuild timer; doc1 push-deploy
  # activates verified closures after Forgejo-signed commits land.
  system.autoUpgrade.enable = lib.mkForce false;

  homelab = {
    services = {
      # Edge Caddy for the legacy appliance proxies only. unifiController +
      # msnHistoryViewer moved to doc2 as standard localProxy/nginx service
      # modules (portable /mnt/virtio state, least-privilege) — see their
      # modules under modules/nixos/services/.
      legacyEdgeCaddy.enable = true;
      # Re-export the scanner drop directory from tower with the older,
      # Brother-compatible standalone Samba policy at \\192.168.1.6\Scans.
      # /mnt/scans is CT 108 mp0, narrowly bind-mounted by prom from
      # the dedicated /mnt/tower-scans NFS mount. Keep it independent of
      # /mnt/tower-data so scanner recovery cannot disrupt igpu CT 107.
      scannerSamba.enable = true;
    };

    ssh = {
      enable = true;
      secure = false;
    };
    tailscale.enable = true;
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = lib.mkForce false;
      pushDeploy.enable = true;
    };
  };

  environment.systemPackages = with pkgs; [
    caddy
    curl
  ];

  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };
  system.activationScripts.sopsAgeKey = {
    deps = ["specialfs"];
    text = ''
      if [ ! -s /var/lib/sops-nix/key.txt ]; then
        install -d -m 0700 /var/lib/sops-nix
        ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > /var/lib/sops-nix/key.txt
        chmod 600 /var/lib/sops-nix/key.txt
      fi
    '';
  };
  system.activationScripts.setupSecrets.deps = lib.mkBefore ["sopsAgeKey"];

  system.stateVersion = "26.11";
}
