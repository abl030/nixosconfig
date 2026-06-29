# igpu as an UNPRIVILEGED Proxmox LXC (staged — NOT yet wired into hosts.nix).
# ===========================================================================
# At cutover, flip the `igpu` entry in hosts.nix:
#     configurationFile = ./hosts/igpu/configuration-lxc.nix;  # was ./configuration.nix
# Full runbook: docs/wiki/infrastructure/igpu-lxc-migration.md
#
# Hostname stays `igpu` (same localIp .33, same fleet trust). The CT gets a FRESH
# SSH host key (igpu is locked, so the VM's root-only key can't be reused), so at
# cutover: update the `igpu` publicKey in hosts.nix to the CT's new host key, and
# re-key secrets/hosts/igpu/* for the CT's derived age key (`sops updatekeys` from
# inside secrets/, editor key on doc1). The four GPU workloads (tdarr-node,
# jellyfin, whisper-server, mailsearch.embed) are unchanged — they reach the
# host-bound iGPU via the bind-mounted /dev/dri/renderD128 + render-group membership.
{
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    # Proxmox LXC profile: sets boot.isContainer, drops bootloader/initrd, wires
    # the container getty + nix path registration.
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    # NOTE: ./hardware-configuration.nix is intentionally NOT imported (it is
    # VM disk/boot/efi boilerplate that cannot apply in a container).
  ];

  proxmoxLXC = {
    privileged = false;
    # NixOS owns networking (config-as-truth; avoids nixpkgs#390932 where Proxmox
    # net injection drops DNS/hostname).
    manageNetwork = true;
    manageHostName = true;
  };

  # ---- Networking (was ens18 on the VM; eth0 in the CT) --------------------
  networking = {
    hostName = "igpu";
    useDHCP = false;
    interfaces.eth0.ipv4.addresses = [
      {
        address = "192.168.1.33";
        prefixLength = 24;
      }
    ];
    defaultGateway = "192.168.1.1";
    nameservers = ["192.168.1.1"]; # pfSense unbound
    # boot.isContainer defaults useHostResolvConf=true, which conflicts with
    # base.nix's systemd-resolved. Let NixOS/resolved own resolv.conf instead.
    useHostResolvConf = lib.mkForce false;
  };

  # ---- Neutralise VM/bare-metal-isms inherited from base.nix --------------
  # base.nix sets these as mkDefault; proxmox-lxc.nix sets isContainer which makes
  # the bootloader inert, but force them off explicitly for clarity/safety.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  # No block device to trim in a CT (base.nix / homelab.update enable fstrim).
  services.fstrim.enable = lib.mkForce false;
  # fs.inotify.max_user_watches is a HOST-wide knob — must be set on prom, not here.
  # (jellyfin/syncthing inotify watches are governed by the host kernel.)

  # ---- GPU: host owns amdgpu; CT just needs Mesa userspace + render group --
  # The kernel driver + firmware live on prom. prom has TWO GPUs: the GTX 1080
  # (nouveau, renderD128) and this iGPU (amdgpu, 7a:00.0). The iGPU enumerates
  # SECOND, so its render node is /dev/dri/renderD129 — that's what the CT's
  # `dev0` passes in (gid=303,mode=0660). radeonsi (VAAPI) + radv (Vulkan) both
  # ride this single node — no /dev/kfd, no privileged CT.
  hardware.graphics.enable = true;
  # Pin render GID to match the CT config's `dev0 gid=303` (NixOS static render gid).
  users.groups.render.gid = 303;
  # jellyfin transcodes via the iGPU's render node, which is renderD129 here (the
  # GTX 1080 takes renderD128). Point it directly at the right node. radv services
  # (whisper/mailsearch) auto-detect the amdgpu node and need nothing. NOTE: if prom
  # ever boots with the GTX 1080 on vfio (gaming VM onboot), the iGPU could become
  # renderD128 — then update this + the CT's dev0. See igpu-lxc-migration.md.
  services.jellyfin.hardwareAcceleration.device = lib.mkForce "/dev/dri/renderD129";

  users.users.abl030.extraGroups = ["video" "render"];

  # ---- Pin migrated service UIDs so the host-side chown stays valid across
  # rebuilds (unprivileged CT: host owner = these + 100000). See migration doc. ----
  users.users.jellyfin.uid = 997;
  users.groups.jellyfin.gid = 997;
  users.users.whisper-server.uid = 988;
  users.groups.whisper-server.gid = 986;

  # ---- CT-specific disables (meaningless or blocked in an unprivileged LXC) ----
  networking.wireless.enable = lib.mkForce false; # no wifi — kills the failing wpa_supplicant
  system.autoUpgrade.enable = lib.mkForce false; # deploy via fleet-deploy; the CT can't arm the realtime upgrade timer
  # (syncthing is disabled by dropping syncthingDeviceId from this host's hosts.nix entry.)

  # ---- Workloads (unchanged from the VM) ----------------------------------
  homelab = {
    # mergerfs STAYS (fuse works in the CT via features=fuse=1). Its branches
    # (/mnt/virtio/media_metadata RW : /mnt/data/Media/* RO) are satisfied by the
    # Proxmox bind-mounts mp0(/mnt/virtio) + mp1(/mnt/data). systemd auto-tracks
    # those externally-provided mounts, satisfying the units' mnt-data.mount dep.
    mounts = {
      fuse.enable = true;
      # nfsLocal is DROPPED: an unprivileged CT cannot mount NFS. The tower exports
      # are mounted on prom and bind-mounted in (mp1 /mnt/data, mp2 /mnt/appdata).
      nfsLocal.enable = false;
    };

    services.tdarrNode = {
      enable = true;
      renderDevice = "/dev/dri/renderD129"; # iGPU node in the CT (mapped to renderD128 in-container)
    };

    services.jellyfin = {
      enable = true;
      dataRoot = "/mnt/virtio/jellyfin";
    };

    services.whisper-server = {
      enable = true;
      dataDir = "/mnt/virtio/whisper-server";
      models = {
        small = "tiny.en";
        medium = "small.en";
        large = "large-v3-turbo";
      };
      defaultModel = "large";
    };

    services.mailsearch = {
      enable = false; # embed backend only — no index/MCP here
      embed = {
        enable = true;
        gpu = true;
        host = "192.168.1.33"; # igpu localIp — bind the LAN IP, never 0.0.0.0
        allowFrom = ["192.168.1.35" "192.168.1.36"]; # doc2's two NICs
        modelsDir = "/var/lib/mailsearch-embed/models";
        parallel = 1; # 2-CU iGPU ceiling — context-loss above this (GPU limit, not LXC)
      };
    };

    ssh = {
      enable = true;
      secure = false;
    };
    tailscale.enable = true; # needs the CT's dev1 = /dev/net/tun
    mdnsReflector = {
      enable = true;
      interfaces = ["eth0"]; # was ens18 on the VM
    };
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = lib.mkForce false; # no block device in a CT
      # rebootOnKernelUpdate is moot in a CT (host owns the kernel). The reset bug
      # that motivated rebootOnKernelUpdate=false is GONE with host-bound amdgpu.
    };
  };

  # ---- sops: identical mechanism to the VM (derive the age key from the host's
  # SSH key). The CT's host key is FRESH, so secrets/hosts/igpu/* must be re-keyed
  # to the CT's age recipient at cutover (update .sops.yaml + `sops updatekeys`).
  # ---------------------------------------------------------------------------
  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };
  system = {
    activationScripts.sopsAgeKey = {
      deps = ["specialfs"];
      text = ''
        if [ ! -s /var/lib/sops-nix/key.txt ]; then
          install -d -m 0700 /var/lib/sops-nix
          ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > /var/lib/sops-nix/key.txt
          chmod 600 /var/lib/sops-nix/key.txt
        fi
      '';
    };
    activationScripts.setupSecrets.deps = lib.mkBefore ["sopsAgeKey"];
    stateVersion = "25.05";
  };

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    libva-utils # vainfo (VAAPI verification)
    vulkan-tools # vulkaninfo (radv verification)
    radeontop
    nvtopPackages.amd
  ]);
}
