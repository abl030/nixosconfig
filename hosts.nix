# Host Definitions & Fleet Trust
# ============================
#
# 1. Host Identity
#    The attribute name (e.g., "epimetheus") serves as the unique ID for the host.
#    The 'sshAlias' is used for SSH config shortcuts (e.g., `ssh epi`).
#    The 'hostname' must match the machine's actual hostname (for NixOS config).
#
# 2. Host Trust (Public Keys)
#    This file acts as the source of truth for the fleet's 'known_hosts'.
#    Each host entry must have a 'publicKey' attribute containing its
#    /etc/ssh/ssh_host_ed25519_key.pub.
#
#    MANUAL KEY RETRIEVAL:
#    If the script fails, run this on the target host to get the string:
#      $ cat /etc/ssh/ssh_host_ed25519_key.pub
#
let
  masterKeys = [
    # Master Fleet Identity
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity"
    # Manual Keys
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJnFw/zW4X+1pV2yWXQwaFtZ23K5qquglAEmbbqvLe5g root@pihole"
    # Termux on Galaxy A55 — separate identity, revocable if phone is lost
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHmUU7BKMmjF53n0uCOg1w6uRe1erG13nembAiIE8ybN phone-fleet@s-a55"
  ];
in {
  epimetheus = {
    configurationFile = ./hosts/epi/configuration.nix;
    homeFile = ./hosts/epi/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "epimetheus";
    sshAlias = "epi";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGuTUS6W9BBOpoDWU7f1jUtlA3B1niCfEtuutfIKPYdr";
    authorizedKeys = masterKeys;
    syncthingDeviceId = "ZUEV7QP-JVG3ZE3-UIVJBSW-RMJ55TN-ZJRBGBX-5442PJS-3A2SMMI-RU7NAAX";
  };

  caddy = {
    homeFile = ./hosts/caddy/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "caddy";
    sshAlias = "cad";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGfVo+vSFpz+oRQqC+ZbGgDzJMRlmydMidZISurihzTZ";
    authorizedKeys = masterKeys;
  };

  framework = {
    configurationFile = ./hosts/framework/configuration.nix;
    homeFile = ./hosts/framework/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030"; # keep as a plain string for Home Manager
    hostname = "framework";
    sshAlias = "fra";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP0atvH47232nLwq1b4P7583cj+WGJYHU4vx/4lgtNgl";
    authorizedKeys = masterKeys;
    syncthingDeviceId = "Z4IPNF4-564WG7C-IYNIPPN-WSQHH74-RCBMJV3-KIJ3PJT-KS4HBF3-JVDPWAY";
  };

  wsl = {
    configurationFile = ./hosts/wsl/configuration.nix;
    homeFile = ./hosts/wsl/home.nix;
    user = "nixos";
    homeDirectory = "/home/nixos";
    hostname = "wsl"; # Added to match ssh.nix
    sshAlias = "wsl"; # Added to match ssh.nix
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFKj3zCDzBVEYSUTyCN4QIDU5S8uUP/NdPi0T8wk0HF root@wsl"; # <--- PASTE HERE
    authorizedKeys = masterKeys;
    sudoPasswordless = true;
    syncthingDeviceId = "5HJSG3P-3LHIT3B-77EMHZP-FIOUOSN-FULX6IU-BQBGLNZ-UUJKAJM-Q67CHA2";
    # Windows host LAN IP at the Cullen office. Cloudflare A records for
    # services exposed via homelab.localProxy point here; Windows then
    # port-forwards 443 into the WSL VM's eth0.
    localIp = "192.168.100.128";
  };

  proxmox-vm = {
    configurationFile = ./hosts/proxmox-vm/configuration.nix;
    homeFile = ./hosts/proxmox-vm/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "proxmox-vm"; # Note: ssh.nix used "nixos", assuming "proxmox-vm" is the correct Tailscale name
    sshAlias = "doc1";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOJrhodI7gb1zaitbZayGHtpc+CO3MfFHK1+DG4Y6IZw root@nixos";
    authorizedKeys = masterKeys;
    sudoPasswordless = true;
    syncthingDeviceId = "YQV3LUJ-MDJZYGB-7S7G3EM-DG6JFRV-SMBEGXH-OM2YYHE-63YVDT7-EE5YMAI";
    localIp = "192.168.1.29";
    tailscaleIp = "100.89.160.60";
  };

  igpu = {
    configurationFile = ./hosts/igpu/configuration.nix;
    homeFile = ./hosts/igpu/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "igpu";
    localIp = "192.168.1.33";
    tailscaleIp = "100.112.123.5";
    sshAlias = "igp";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPucrnfLpTjCzItnNPvGJ0iqQs2+iTyTXZH5pCBpuvDp root@nixos";
    authorizedKeys = masterKeys;
    syncthingDeviceId = "IJ3FS4G-DBM47AW-WEEM7W3-VCEOYP4-K6QRJLG-LHRZMJH-EMNN4IS-ZVHX6QF";
  };

  dev = {
    configurationFile = ./hosts/dev/configuration.nix;
    homeFile = ./hosts/dev/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "dev";
    sshAlias = "dev";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILAmI3odA5l/E+hAN0W9CyIrXupYGOevMdqSyladVqsX";
    authorizedKeys = masterKeys;
    syncthingDeviceId = "SDQORDI-5A2PG3X-PUXSXH6-EKSB3XD-H3S23CP-OX3PMSK-BBPYEGU-XGZWBQJ";
  };

  # =============================================================
  # SANDBOX VM - Isolated development environment for Claude Code
  # =============================================================
  # Security Model:
  # - Fleet machines CAN SSH in (via masterKeys in authorizedKeys)
  # - NO fleet identity key deployed (cannot SSH to other fleet hosts)
  # - Firewall blocks local network (192.168.x.x, 10.x.x.x, 172.16.x.x)
  # - Internet access allowed (for Claude Code, packages, etc.)
  # - Tailscale enabled for fleet access
  # - Firewall changes require sudo (root)
  # =============================================================
  sandbox = {
    configurationFile = ./hosts/sandbox/configuration.nix;
    homeFile = ./hosts/sandbox/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "sandbox";
    sshAlias = "sbx";
    # NOTE: sshKeyName intentionally omitted - no fleet identity deployed
    # The homelab.ssh.deployIdentity = false in configuration.nix handles this
    initialHashedPassword = "$6$58mDYkJdHY9JTiTU$whCjz4eG3T9jPajUIlhqqBJ9qzqZM7xY91ylSy.WC2MkR.ckExn0aNRMM0XNX1LKxIXL/VJe/3.oizq2S6cvA0"; # temp123
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHg+0cl2eSRJP0uMoScnKY9J6ZvYERwjc843qO2BNqfB";
    authorizedKeys = masterKeys; # Fleet CAN access this VM
  };

  doc2 = {
    configurationFile = ./hosts/doc2/configuration.nix;
    homeFile = ./hosts/doc2/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "doc2";
    sshAlias = "doc2";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPv9MVIv00FafaGR/mPE3nW565bycshuwxlh3vhT+bZp";
    authorizedKeys = masterKeys;
    sudoPasswordless = true; # temporary — lock down once appliance is stable
    localIp = "192.168.1.35";
    tailscaleIp = "100.87.177.120";
    gotifyServer = true;
  };

  cache = {
    configurationFile = ./hosts/cache/configuration.nix;
    homeFile = ./hosts/cache/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "cache";
    sshAlias = "cache";
    sshKeyName = "ssh_key_abl030";
    initialHashedPassword = "$6$58mDYkJdHY9JTiTU$whCjz4eG3T9jPajUIlhqqBJ9qzqZM7xY91ylSy.WC2MkR.ckExn0aNRMM0XNX1LKxIXL/VJe/3.oizq2S6cvA0"; # temp123
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHYh5BYMlU8u7RGjChPe7QON+adENp+SUtg2+HYAV9FD";
    authorizedKeys = masterKeys;
    syncthingDeviceId = "VFUAMOE-ID4MCL2-KQZX22M-BUCYDOM-KSHMW2Y-XYYBJI4-2FD77RH-RPGOOAJ";
  };
}
