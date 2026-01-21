{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];

  # Match template 9003 bootloader (GRUB)
  boot.loader = {
    systemd-boot.enable = false;
    efi.canTouchEfiVariables = false;
    grub = {
      enable = true;
      devices = ["nodev"];
    };
  };

  homelab = {
    ssh = {
      enable = true;
      secure = false; # Allow password auth initially for provisioning
      deployIdentity = false; # DO NOT deploy fleet identity key - sandbox isolation
    };
    tailscale.enable = true;
    # Use external caches only - disable internal network caches
    nixCaches = {
      enable = true;
      profile = "external";
      # Disable internal caches since firewall blocks local network
      nixServe.enable = false;
      mirror.enable = false;
    };
    # Disable auto-updates - this is a controlled sandbox
    update.enable = false;
    containers = {
      enable = true;
      dataRoot = "/home/abl030/podman-data";
      autoUpdate.enable = false;
    };
  };

  # Enable QEMU guest agent for Proxmox integration
  services.qemuGuest.enable = true;

  # =============================================================
  # SANDBOX ISOLATION FIREWALL
  # =============================================================
  # This firewall configuration isolates the VM from the local network
  # while allowing:
  # - Inbound SSH from Tailscale (fleet access)
  # - Outbound internet (for Claude Code, package downloads, etc.)
  # - Tailscale mesh traffic
  #
  # BLOCKED:
  # - All RFC1918 private networks (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
  # - Direct local network access
  #
  # Changing these rules requires sudo (root), providing a safety barrier.
  # =============================================================

  networking.firewall = {
    enable = true;

    # Allow SSH on Tailscale interface only
    interfaces.tailscale0 = {
      allowedTCPPorts = [22];
    };

    # Block outbound to RFC1918 private networks
    extraCommands = ''
      # Get the primary network interface (not lo, not tailscale0)
      PRIMARY_IFACE=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gawk}/bin/awk '/default/ {print $5; exit}')

      # Block outbound to RFC1918 private networks on primary interface
      ${pkgs.iptables}/bin/iptables -I OUTPUT -o "$PRIMARY_IFACE" -d 10.0.0.0/8 -j REJECT --reject-with icmp-net-unreachable 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -I OUTPUT -o "$PRIMARY_IFACE" -d 172.16.0.0/12 -j REJECT --reject-with icmp-net-unreachable 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -I OUTPUT -o "$PRIMARY_IFACE" -d 192.168.0.0/16 -j REJECT --reject-with icmp-net-unreachable 2>/dev/null || true

      # Allow Gotify (internal notification server)
      ${pkgs.iptables}/bin/iptables -I OUTPUT -o "$PRIMARY_IFACE" -d 192.168.1.6 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true

      # Allow established/related connections (needed for responses)
      ${pkgs.iptables}/bin/iptables -I OUTPUT -o "$PRIMARY_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

      # Allow DNS
      ${pkgs.iptables}/bin/iptables -I OUTPUT -o "$PRIMARY_IFACE" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -I OUTPUT -o "$PRIMARY_IFACE" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true

      # Allow DHCP
      ${pkgs.iptables}/bin/iptables -I OUTPUT -o "$PRIMARY_IFACE" -p udp --dport 67:68 -j ACCEPT 2>/dev/null || true

      # Allow Tailscale UDP port
      ${pkgs.iptables}/bin/iptables -I OUTPUT -o "$PRIMARY_IFACE" -p udp --dport 55500 -j ACCEPT 2>/dev/null || true
    '';

    extraStopCommands = ''
      PRIMARY_IFACE=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gawk}/bin/awk '/default/ {print $5; exit}')
      ${pkgs.iptables}/bin/iptables -D OUTPUT -o "$PRIMARY_IFACE" -d 10.0.0.0/8 -j REJECT --reject-with icmp-net-unreachable 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -D OUTPUT -o "$PRIMARY_IFACE" -d 172.16.0.0/12 -j REJECT --reject-with icmp-net-unreachable 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -D OUTPUT -o "$PRIMARY_IFACE" -d 192.168.0.0/16 -j REJECT --reject-with icmp-net-unreachable 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -D OUTPUT -o "$PRIMARY_IFACE" -d 192.168.1.6 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -D OUTPUT -o "$PRIMARY_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -D OUTPUT -o "$PRIMARY_IFACE" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -D OUTPUT -o "$PRIMARY_IFACE" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -D OUTPUT -o "$PRIMARY_IFACE" -p udp --dport 67:68 -j ACCEPT 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -D OUTPUT -o "$PRIMARY_IFACE" -p udp --dport 55500 -j ACCEPT 2>/dev/null || true
    '';
  };

  # Use external DNS servers to avoid local DNS dependency
  networking.nameservers = ["1.1.1.1" "8.8.8.8"];

  # Restart firewall after network is online to ensure OUTPUT rules apply
  # (The firewall starts before network-pre.target, so PRIMARY_IFACE detection fails)
  systemd.services.firewall-reload-after-network = {
    description = "Reload firewall after network is online";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "firewall.service"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart firewall.service";
      RemainAfterExit = true;
    };
  };

  # Development tools for Claude Code autonomous development
  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    htop
    vim
    git
    curl
    wget
    jq
    ripgrep
    fd
    tree
    gnumake
    gcc
    nodejs
    python3
    openssh
  ]);

  system.stateVersion = "25.05";
}
