# Live Cullen file-server shares on doc1, mounted on demand over the Cullen
# laptop's Tailscale subnet route (192.168.100.0/24).
#
#   /mnt/cullen/z  = //192.168.100.201/Data      read-write
#   /mnt/cullen/y  = //192.168.100.201/Accounts  read-only (client side)
#
# Replaces the "Z broker" (an SSH + PowerShell job runner on CW-DC01) that
# cullen-assistant used for live reads/writes; it hung too often and cost
# ~8-12 s per call. The assistant repo's scripts/z keeps its safety rails
# (sha check, Office-lock refusal, local backup) on top of this mount.
#
# Auth: dedicated AD account CULLENWINES\svc-doc1 (password never expires,
# member of Domain Users + "Accounts Folder Access", no RDP), so share and
# NTFS ACLs apply, unlike the broker which ran as domain admin. The
# mount.cifs credentials file is root-only; files appear as abl030 0600.
#
# Failure mode: the route depends on the Cullen laptop. The mounts are
# automount + soft with short timeouts so a dead route returns an error in
# ~20 s instead of hanging processes in D state; idle mounts drop after
# 10 min. _netdev + nofail keep them out of local-fs.target (see
# docs/wiki/infrastructure/systemd-mount-ordering-cycles.md).
{
  config,
  pkgs,
  ...
}: let
  creds = config.sops.secrets."cullen/smb-credentials".path;
  common = [
    "credentials=${creds}"
    "vers=3.1.1"
    "uid=abl030"
    "gid=users"
    "file_mode=0600"
    "dir_mode=0700"
    "soft"
    "echo_interval=10"
    "noserverino"
    "nobrl"
    "actimeo=1"
    "noauto"
    "nofail"
    "_netdev"
    "x-systemd.automount"
    "x-systemd.idle-timeout=600"
    "x-systemd.mount-timeout=20"
  ];
in {
  environment.systemPackages = [pkgs.cifs-utils];

  # username=/password=/domain= lines (mount.cifs credentials format).
  sops.secrets."cullen/smb-credentials" = {
    sopsFile = config.homelab.secrets.sopsFile "cullen-smb.cred";
    format = "binary";
    owner = "root";
    mode = "0400";
  };

  fileSystems."/mnt/cullen/z" = {
    device = "//192.168.100.201/Data";
    fsType = "cifs";
    options = common;
  };

  fileSystems."/mnt/cullen/y" = {
    device = "//192.168.100.201/Accounts";
    fsType = "cifs";
    options = common ++ ["ro"];
  };
}
