{
  lib,
  pkgs,
  inputs,
  hostConfig,
  ...
}: {
  imports = [
    inputs.nixos-wsl.nixosModules.default
    ../common/desktop.nix
  ];

  # --- Base.nix Overrides for WSL ---
  # WSL uses its own bootloader logic, conflicting with systemd-boot
  boot.loader.systemd-boot.enable = false;
  # WSL doesn't use standard NetworkManager logic
  networking.networkmanager.enable = false;
  # WSL manages /etc/resolv.conf itself (wsl.wslConf.network.generateResolvConf).
  # nixos-wsl sets environment.etc."resolv.conf".enable = false, which trips
  # the upstream resolvconf assertion (checks for attr presence, not enable).
  networking.resolvconf.enable = false;
  # Opt out of base.nix's systemd-resolved default (#262). With NM disabled and
  # DNS bridged from the Windows host, resolved would fight WSL's own resolv.conf
  # management. (networking.networkmanager.dns from base is inert here — NM off.)
  services.resolved.enable = false;
  # fstrim is handled by the host OS / WSL engine usually
  services.fstrim.enable = false;

  homelab = {
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = false; # Redundant with service disable, but good for clarity
    };
    ssh.enable = true;
    # Tailscale runs on the WINDOWS host, not in WSL (a second tailscaled fought
    # the host's and broke connectivity). SSH-from-tailnet is bridged via a
    # Windows-side netsh portproxy + scheduled task — see
    # docs/wiki/infrastructure/wsl-tailscale-ssh.md
    tailscale.enable = false;
    mounts = {
      nfs = {
        enable = true;
        server = "192.168.1.2"; # Via Windows Tailscale subnet route
        appdata = false;
      };
      drvfs = {
        enable = true;
        drives.z = {
          label = "Z:";
          mountPoint = "/mnt/z";
        };
      };
      opsSync.enable = true;
      nfsMusic.enable = false;
    };
    services.cullen-dashboard.enable = true;
    # cullen-dashboard syncs Vinsight via /run/secrets/mcp/vinsight.env. Base
    # default is OFF fleet-wide (#234 scoped MCP creds to doc1). WSL is the host
    # that actually runs the dashboard, so it opts in to vinsight ONLY — none of
    # the infra-control tokens (pfsense/unifi/HA). Secret lives at
    # secrets/hosts/wsl/vinsight-mcp.env (WSL host key + editor + break-glass).
    mcp = {
      enable = true;
      vinsight.enable = true;
    };
  };

  # Suppress duplicate filesystem metric warnings for /run/user tmpfs
  services.prometheus.exporters.node.extraFlags = [
    "--collector.filesystem.mount-points-exclude=^/run/user"
  ];

  # Docker for container-based development/testing
  virtualisation.docker.enable = true;
  users.users.${hostConfig.user}.extraGroups = ["docker"];

  # 3. Standard WSL Configuration
  wsl.enable = true;
  wsl.defaultUser = hostConfig.user;

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    neovim
    gh
  ]);

  system.stateVersion = "25.05";
}
