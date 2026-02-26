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
# 3. Proxmox VMs (Optional)
#    Hosts running on Proxmox can have a 'proxmox' attribute with VM specs.
#    This is the single source of truth for OpenTofu/Terranix provisioning.
#    Set 'readonly = true' for VMs that should not be managed by automation.
#
let
  masterKeys = [
    # Master Fleet Identity
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity"
    # Manual Keys
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJnFw/zW4X+1pV2yWXQwaFtZ23K5qquglAEmbbqvLe5g root@pihole"
  ];
in {
  # Proxmox Infrastructure Configuration
  # Used by OpenTofu/Terranix for VM provisioning
  _proxmox = {
    host = "192.168.1.12";
    node = "prom";
    defaultStorage = "nvmeprom";
    templateVmid = 9003;
  };

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
    containerStacks = [
      "restart-probe"
      "restart-probe-b"
    ];
    syncthingDeviceId = "5HJSG3P-3LHIT3B-77EMHZP-FIOUOSN-FULX6IU-BQBGLNZ-UUJKAJM-Q67CHA2";
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
    # Stacks disabled for testing - enable one by one
    containerStacks = [
      "management"
      "tailscale-caddy"
      # "paperless" — migrated to native NixOS services on doc2
      # "mealie" — migrated to native NixOS services on doc2
      "kopia"
      "domain-monitor"
      "invoices"
      "jdownloader2"
      # "music" — migrated to native NixOS services on doc2
      "netboot"
      "smokeping"
      # "stirlingpdf" — migrated to native NixOS services on doc2
      "uptime-kuma"
      # "webdav" — migrated to native NixOS services on doc2
      "youtarr"
      "musicbrainz"
    ];
    proxmox = {
      vmid = 104;
      cores = 8;
      memory = 32000;
      disk = "400G";
      name = "Doc1";
      bios = "ovmf";
      cpuType = "x86-64-v3";
      diskInterface = "scsi0";
      cloneFromTemplate = false; # imported VM; no clone block
      ignoreInit = true; # keep existing cloud-init settings
      tags = [];
      ignoreChangesExtra = [
        "description"
        "tags"
        "keyboard_layout"
        "migrate"
        "on_boot"
        "reboot"
        "stop_on_destroy"
        "timeout_clone"
        "timeout_create"
        "timeout_migrate"
        "timeout_reboot"
        "timeout_shutdown_vm"
        "timeout_start_vm"
        "timeout_stop_vm"
        "operating_system"
        "cpu"
        "memory"
        "agent"
        "scsi_hardware"
        "network_device"
        "disk"
        "efi_disk"
        "machine"
        "vga"
        "initialization"
      ];
      readonly = false; # Managed by OpenTofu
    };
  };

  igpu = {
    configurationFile = ./hosts/igpu/configuration.nix;
    homeFile = ./hosts/igpu/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "igpu";
    containerStacks = ["igpu-management" "tdarr-igp" "jellyfin" "plex" "loki" "restart-probe"];
    localIp = "192.168.1.33";
    sshAlias = "igp";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPucrnfLpTjCzItnNPvGJ0iqQs2+iTyTXZH5pCBpuvDp root@nixos";
    authorizedKeys = masterKeys;
    syncthingDeviceId = "IJ3FS4G-DBM47AW-WEEM7W3-VCEOYP4-K6QRJLG-LHRZMJH-EMNN4IS-ZVHX6QF";
    proxmox = {
      vmid = 109;
      cores = 8;
      memory = 8096;
      disk = "150G";
      storage = "Test";
      bios = "ovmf";
      cpuType = "host";
      machine = "q35";
      diskInterface = "scsi0";
      cloneFromTemplate = false; # imported VM; no clone block
      ignoreInit = true; # keep existing cloud-init settings
      tags = [];
      ignoreChangesExtra = [
        "description"
        "tags"
        "keyboard_layout"
        "migrate"
        "on_boot"
        "reboot"
        "stop_on_destroy"
        "timeout_clone"
        "timeout_create"
        "timeout_migrate"
        "timeout_reboot"
        "timeout_shutdown_vm"
        "timeout_start_vm"
        "timeout_stop_vm"
        "operating_system"
        "cpu"
        "memory"
        "agent"
        "scsi_hardware"
        "network_device"
        "disk"
        "efi_disk"
        "machine"
        "vga"
        "hostpci"
        "initialization"
      ];
      readonly = false; # Managed by OpenTofu
    };
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
    proxmox = {
      vmid = 110;
      cores = 4;
      memory = 12192;
      disk = "64G";
      bios = "ovmf";
      cpuType = "qemu64";
      machine = "q35";
      diskInterface = "scsi0";
      cloneFromTemplate = false; # imported VM; no clone block
      ignoreInit = true; # keep existing cloud-init settings
      tags = [];
      ignoreChangesExtra = [
        "description"
        "tags"
        "keyboard_layout"
        "migrate"
        "on_boot"
        "reboot"
        "stop_on_destroy"
        "timeout_clone"
        "timeout_create"
        "timeout_migrate"
        "timeout_reboot"
        "timeout_shutdown_vm"
        "timeout_start_vm"
        "timeout_stop_vm"
        "operating_system"
        "cpu[0].type"
        "agent[0].type"
      ];
      # readonly = true; # Already exists - don't let OpenTofu recreate it
    };
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
    proxmox = {
      vmid = 111;
      cores = 14;
      memory = 18192;
      disk = "64G";
      # Use defaults to match template 9003:
      # - bios = "seabios" (not ovmf)
      # - diskInterface = "virtio0" (not scsi0)
      # - no machine override
      tags = ["sandbox" "isolated" "claude-code"];
      description = "Isolated sandbox VM for autonomous Claude Code development";
    };
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
    gotifyServer = true;
    proxmox = {
      vmid = 114;
      cores = 8;
      memory = 16384;
      disk = "32G";
      storage = "nvmeprom";
      cpuType = "x86-64-v3";
      tags = ["opentofu" "nixos" "managed"];
      description = "Service appliance VM — native NixOS services on virtiofs storage";
      virtiofs = {
        mapping = "containers";
      };
    };
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
    proxmox = {
      vmid = 112;
      cores = 4;
      memory = 8192;
      disk = "64G";
      storage = "nvmeprom";
      description = "cache";
    };
  };
}
