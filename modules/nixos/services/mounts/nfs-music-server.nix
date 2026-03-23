# NFS server for the local music library on virtiofs
# Exports /mnt/virtio/Music with tight access control
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.nfsMusicServer;
in {
  options.homelab.mounts.nfsMusicServer = {
    enable = mkEnableOption "NFS export of /mnt/virtio/Music";
  };

  config = mkIf cfg.enable {
    # NFS server
    services.nfs.server = {
      enable = true;
      exports = ''
        /mnt/virtio/Music 192.168.1.2(ro,sync,no_subtree_check,no_root_squash) 192.168.1.5(rw,sync,no_subtree_check,no_root_squash) 100.78.17.73(rw,sync,no_subtree_check,no_root_squash)
      '';
    };

    # Open NFS ports only to the three allowed clients
    networking.firewall = {
      extraCommands = ''
        # NFS music share — allow only specific hosts
        for port in 111 2049 20048; do
          for ip in 192.168.1.2 192.168.1.5 100.78.17.73; do
            iptables -A nixos-fw -p tcp -s "$ip" --dport "$port" -j nixos-fw-accept
            iptables -A nixos-fw -p udp -s "$ip" --dport "$port" -j nixos-fw-accept
          done
        done
      '';
      extraStopCommands = ''
        for port in 111 2049 20048; do
          for ip in 192.168.1.2 192.168.1.5 100.78.17.73; do
            iptables -D nixos-fw -p tcp -s "$ip" --dport "$port" -j nixos-fw-accept 2>/dev/null || true
            iptables -D nixos-fw -p udp -s "$ip" --dport "$port" -j nixos-fw-accept 2>/dev/null || true
          done
        done
      '';
    };
  };
}
