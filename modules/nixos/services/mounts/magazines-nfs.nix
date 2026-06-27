# Dedicated NFS mount for the wine-magazine archive (/mnt/magazines).
#
# WHY its own single-purpose mount instead of a subdir of /mnt/data:
# the magazine archive lives on its OWN tower share pinned to a SINGLE
# Unraid array disk (disk1), exported as `192.168.1.2:/mnt/user/magazines`.
# A single XFS disk has STABLE inodes, so it does NOT suffer the shfs
# (FUSE-union) synthetic-inode ESTALE that the multi-disk /mnt/user/data
# union does — that union flapped the GAW leaf's NFS filehandle on write
# and failed gwm-archiver's namespace setup (its ReadWritePaths leaf bind
# resolved a stale handle → status=226/NAMESPACE). Decoupling from /mnt/data
# also means a stale /mnt/data union no longer touches the magazine path.
# See docs/wiki/infrastructure/unraid-nfs-shfs-estale.md.
#
# The tower export is scoped (private) to exactly: doc2 (rw), epi (rw),
# framework (ro, defense-in-depth — it only reads the library). Consumers:
# gwm-archiver (doc2 write), komga + komga-sync (doc2 read), marker-convert
# (epi read/write), kopia-mum + kopia-photos (doc2 read for backup).
#
# Transport per host mirrors nfs.nix/nfs-local.nix: always-on servers (doc2)
# mount STATIC + hard (nothing they back goes stale); roaming/suspending hosts
# (epi, framework) use x-systemd.automount; framework reaches tower over
# Tailscale (external) with soft semantics so a dead tailnet path can't pin
# the kernel.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.magazines;
  useTailscale = cfg.external;
  serverAddr =
    if cfg.external
    then "tower"
    else cfg.server;
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
  automountOpts = lib.optionals cfg.automount [
    "x-systemd.automount"
    "noauto"
    "nofail"
    "x-systemd.idle-timeout=300"
    "x-systemd.mount-timeout=30s"
  ];
  # rw writers (doc2, epi) get hard so a tower blip blocks-and-resumes rather
  # than silently losing a write; the ro roaming reader (framework) gets soft.
  reliabilityOpts =
    if cfg.external
    then ["soft" "timeo=30" "retrans=2"]
    else ["hard" "softreval" "timeo=50" "retrans=5"];
in {
  options.homelab.mounts.magazines = {
    enable = mkEnableOption "dedicated NFS mount of the magazine archive (/mnt/magazines)";
    external = mkEnableOption "reach tower over Tailscale (roaming hosts, e.g. framework)";
    readOnly = mkEnableOption "mount read-only (defense in depth for hosts that only read)";
    automount = mkEnableOption "x-systemd.automount (roaming/suspending hosts; off = static, for always-on servers)";

    server = mkOption {
      type = types.str;
      default = "192.168.1.2";
      description = "NFS server address when external=false (tower LAN IP).";
    };

    mountPoint = mkOption {
      type = types.str;
      default = "/mnt/magazines";
      description = "Local mountpoint for the dedicated magazines export.";
    };
  };

  config = mkIf cfg.enable {
    # The Tailscale fstab options reference tailscale-wait.service by name,
    # opaque to Nix's type system — catch the missing dep at eval time.
    assertions = lib.optional useTailscale {
      assertion = config.homelab.tailscale.enable;
      message = "homelab.mounts.magazines with external=true requires homelab.tailscale.enable = true (the fstab options depend on tailscale-wait.service).";
    };

    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    boot.initrd = {
      supportedFilesystems = lib.mkOrder 1600 ["nfs"];
      kernelModules = lib.mkOrder 1600 ["nfs"];
    };

    fileSystems.${cfg.mountPoint} = {
      device = "${serverAddr}:/mnt/user/magazines";
      fsType = "nfs";
      options =
        ["_netdev" "noatime" "nfsvers=4.2"]
        ++ reliabilityOpts
        ++ automountOpts
        ++ serverRequires
        ++ lib.optional cfg.readOnly "ro";
    };
  };
}
