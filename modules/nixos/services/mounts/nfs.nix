# NFS mounts to Unraid tower
# Mounts /mnt/data and /mnt/appdata with automount on access
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.nfs;
  # `external = true` opts into Tailscale (use the MagicDNS name "tower"),
  # for hosts outside the home LAN (e.g. framework on the road). Hosts at
  # home use the LAN IP by default — fewer dependencies, no Tailscale-
  # readiness race for every NFS op.
  useTailscale = cfg.external || cfg.server == "tower";
  serverAddr =
    if cfg.external
    then "tower"
    else cfg.server;
  # Tower NFS over Tailscale uses tailscale-wait.service (not tailscaled.service)
  # for the same readiness-gap reason /mnt/mum does. See
  # docs/wiki/infrastructure/nfs-over-tailscale.md.
  serverRequires =
    if useTailscale
    then [
      "x-systemd.requires=tailscale-wait.service"
      "x-systemd.after=tailscale-wait.service"
    ]
    else [
      "x-systemd.requires=network-online.target"
      "x-systemd.after=network-online.target"
    ];
in {
  options.homelab.mounts.nfs = {
    enable = mkEnableOption "NFS mounts to tower";

    external = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Use Tailscale to reach tower (via the "tower" MagicDNS name).
        Set this on hosts outside the home LAN (framework when on the
        road). Defaults to false — at-home hosts use the LAN address
        set by the `server` option, avoiding a Tailscale dependency
        on every NFS operation.

        When `external = true`, the server address becomes "tower"
        regardless of what `server` is set to (`external` takes
        precedence). For non-standard topologies that need a
        Tailscale-only mount but with a different address, leave
        `external = false` and set `server` to the desired name —
        but note the routing detector only treats `server == "tower"`
        as the tailnet path; any other name evaluates as LAN routing.
        If you need to add another tailnet server in the future,
        widen the `useTailscale` predicate in this module.
      '';
    };

    server = mkOption {
      type = types.str;
      default = "192.168.1.2";
      description = ''
        NFS server address. Defaults to tower's LAN IP. When
        `external = false`, this is the literal address mount.nfs
        uses. When `external = true`, this option is **overridden**
        (the resulting mount targets "tower" via MagicDNS).
        wsl overrides this directly to its Windows-host-relayed
        subnet route.
      '';
    };

    appdata = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to mount /mnt/appdata. Disable for hosts that don't need it.";
    };
  };

  config = mkIf cfg.enable {
    # When tower NFS goes over Tailscale (external=true or server="tower"),
    # the fstab options reference tailscale-wait.service. Catch missing-dep
    # at eval time instead of as a deploy-time systemd error.
    assertions = lib.optional useTailscale {
      assertion = config.homelab.tailscale.enable;
      message = "homelab.mounts.nfs with external=true (or server=\"tower\") requires homelab.tailscale.enable = true (the tower fstab options depend on tailscale-wait.service).";
    };

    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    boot.initrd = {
      supportedFilesystems = lib.mkOrder 1600 ["nfs"];
      kernelModules = lib.mkOrder 1600 ["nfs"];
    };

    fileSystems."/mnt/data" = {
      device = "${serverAddr}:/mnt/user/data";
      fsType = "nfs";
      options =
        [
          "x-systemd.automount"
          "noauto"
          "_netdev"
          "x-systemd.idle-timeout=300"
          "noatime"
          "nfsvers=4.2"
        ]
        ++ serverRequires;
    };

    fileSystems."/mnt/appdata" = mkIf cfg.appdata {
      device = "${serverAddr}:/mnt/user/appdata";
      fsType = "nfs";
      options =
        [
          "x-systemd.automount"
          "noauto"
          "_netdev"
          "x-systemd.idle-timeout=300"
          "noatime"
          "nfsvers=4.2"
        ]
        ++ serverRequires;
    };
  };
}
