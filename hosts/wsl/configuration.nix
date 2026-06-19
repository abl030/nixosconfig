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

  # forgejo#2: LOCK wsl like every other non-bastion host. base.nix derives
  # wheelNeedsPassword = true from homelab.fleetDeploy.role = "locked" (the
  # default), but NixOS-WSL's wsl-distro.nix sets it `mkDefault false` (WSL wants
  # passwordless sudo) — two mkDefaults of differing values collide, so force it.
  # nixos has no usable password here, so interactive sudo won't work until one
  # is set; break-glass is ALWAYS `wsl -u root` from Windows (root, no password).
  # To restore interactive sudo: `wsl -u root passwd nixos`. Deploy via the
  # nightly nixos-upgrade timer, `wsl -u root fleet-update`, or `fleet-deploy
  # wsl` from doc1 (needs the triggerFrom widening below).
  security.sudo.wheelNeedsPassword = lib.mkForce true;

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

    # forgejo#2: widen the deploy-trigger key's source pin so `fleet-deploy wsl`
    # works. Because of the portproxy above, wsl's sshd sees EVERY connection
    # from the WSL vEthernet gateway (172.26.224.1, in 172.16.0.0/12) — NOT
    # doc1's tailnet IP — so the default from="100.64.0.0/10,192.168.1.0/24"
    # rejects the trigger key (publickey denial). The WSL bridge is wsl's ONLY
    # ingress, so pinning to 172.16/12 is equivalent to LAN-pinning a normal
    # host; the key is still doc1-only + forced-command (systemctl start
    # nixos-upgrade, nothing else). 172.16/12 (not the exact gateway IP) tolerates
    # WSL reassigning the bridge subnet across restarts.
    fleetDeploy.triggerFrom = "100.64.0.0/10,192.168.1.0/24,172.16.0.0/12";
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

  # Docker for container-based development/testing. forgejo#2: nixos is NO LONGER
  # in the `docker` group — docker-group membership is root-equivalent
  # (`docker run -v /:/host …`), which would have made the sudo lock above
  # pure theatre. The daemon stays enabled but is now root-only: use it via
  # `wsl -u root docker …` (or `sudo docker …` once a password is set). If you
  # want frictionless docker as nixos again WITHOUT the root door, switch to
  # rootless (`virtualisation.docker.rootless.enable`) — userns-isolated, no
  # root-equivalence — rather than re-adding the group.
  virtualisation.docker.enable = true;

  # 3. Standard WSL Configuration
  wsl.enable = true;
  wsl.defaultUser = hostConfig.user;

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    neovim
    gh
  ]);

  system.stateVersion = "25.05";
}
