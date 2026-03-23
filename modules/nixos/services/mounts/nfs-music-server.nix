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
    # NFS exports:
    #   192.168.1.2   = tower (Unraid) — read-only
    #   192.168.1.5   = epimetheus (desktop) — read-write over LAN
    #   100.78.17.73  = framework (laptop) — read-write over Tailscale
    #   100.75.246.114 = WSL (via Windows host Tailscale) — read-write
    services.nfs.server = {
      enable = true;
      exports = ''
        /mnt/virtio/Music 192.168.1.2(ro,sync,no_subtree_check,no_root_squash,fsid=100) 192.168.1.5(rw,sync,no_subtree_check,no_root_squash,fsid=100) 100.78.17.73(rw,sync,no_subtree_check,no_root_squash,fsid=100) 100.75.246.114(rw,sync,no_subtree_check,no_root_squash,fsid=100)
      '';
    };

    # Open NFS ports only to the allowed clients (see IP list above)
    networking.firewall = {
      extraCommands = ''
        # NFS music share — allow only specific hosts
        for port in 111 2049 20048; do
          for ip in 192.168.1.2 192.168.1.5 100.78.17.73 100.75.246.114; do
            iptables -A nixos-fw -p tcp -s "$ip" --dport "$port" -j nixos-fw-accept
            iptables -A nixos-fw -p udp -s "$ip" --dport "$port" -j nixos-fw-accept
          done
        done
      '';
      extraStopCommands = ''
        for port in 111 2049 20048; do
          for ip in 192.168.1.2 192.168.1.5 100.78.17.73 100.75.246.114; do
            iptables -D nixos-fw -p tcp -s "$ip" --dport "$port" -j nixos-fw-accept 2>/dev/null || true
            iptables -D nixos-fw -p udp -s "$ip" --dport "$port" -j nixos-fw-accept 2>/dev/null || true
          done
        done
      '';
    };
  };
}
