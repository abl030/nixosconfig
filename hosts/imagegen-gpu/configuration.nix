# imagegen-gpu — GPU image-generation appliance, NixOS VM on prom (VM 123).
#
# Phase 2 of the local image-generation work. Phase 1 (`imagegen`, CT 110) runs
# stable-diffusion.cpp on the 9950X's AVX-512 cores; this host runs the same
# binary against the GTX 1080 that normally belongs to the gaming VMs, so the
# two are directly comparable. Findings: docs/wiki/services/imagegen-gpu.md.
#
# Why a VM and not an LXC. The 1080 is bound to vfio-pci on prom for
# passthrough, so it cannot be handed to a container. Passing it to a *VM* also
# buys mutual exclusion for free: Proxmox refuses to start a second guest that
# claims the same PCI device, so this host can never steal the GPU out from
# under a running apollo-* gaming VM. That is the whole reason for the VM shape.
#
# Normally ON (`onboot 1`): this is the image box now — the CPU sibling was
# retired on 2026-09-09 because a 20-30 minute all-cores job made the whole
# hypervisor sluggish. It costs ~12 GiB of prom's RAM while running (KVM pins
# its allocation; prom has no swap), which is the price of a UI that is just
# there. To game: start the gaming VM — a prom hookscript
# (local:snippets/imagegen-exclusive.sh, wired to VMs 117/120/121) shuts this
# one down first so the card is free; start it again afterwards.
#
# Serves ComfyUI at https://imagegen.ablz.au through the fleet's nginx/ACME
# local proxy. Not public: the A record and the nginx bind are the LAN IP, and
# ComfyUI has no authentication, so it must never get a public path. No
# tailnet membership either.
#
# The only sops secret it consumes is the shared acme-cloudflare.env (for the
# certificate); privateFlakeAuth + atuinCredentials are false in hosts.nix and
# there is deliberately no secrets/hosts/imagegen-gpu/ directory.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware-configuration.nix
  ];

  boot = {
    # OVMF + systemd-boot, unlike doc2/servarr's seabios + GRUB. See disko.nix
    # for why: this host is installed offline from doc1 (the diskoImages path
    # is broken against this nixpkgs pin), and an offline systemd-boot install
    # is a file copy into the ESP. canTouchEfiVariables stays false because the
    # install happens on a BIOS-booted build host with no efivarfs, and because
    # bootctl also writes the removable \EFI\BOOT\BOOTX64.EFI fallback that
    # OVMF boots without any NVRAM entry.
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = false;
    };

    # The installed image is 16 GiB so the build and the copy to prom stay
    # quick; the real virtio0 is far larger (model weights are tens of GiB).
    # Root is the last partition, which is growpart's requirement.
    #
    # `growPartition` alone is NOT enough and this host proved it: the module
    # only runs growpart, which grows the *partition*. Growing the ext4 inside
    # it is a separate step that systemd only performs for mounts carrying
    # `x-systemd.growfs` (see fileSystems below). Without that the first boot
    # came up with a 200 GiB partition and a 16 GiB filesystem.
    growPartition = true;

    # nouveau cannot coexist with the proprietary driver, and this guest has no
    # use for it — the passed-through 1080 is a compute device, not a display.
    blacklistedKernelModules = ["nouveau"];

    # Headless appliance with no keyboard: put the kernel log on the Proxmox
    # serial socket so `qm terminal 123` on prom shows the boot. Cheap, and the
    # only way to see why a network-less boot went wrong.
    kernelParams = ["console=tty0" "console=ttyS0,115200"];
  };

  # -- GPU: headless CUDA, not a desktop -------------------------------------
  #
  # Deliberately NOT `homelab.gpu.nvidia`. That module is written for the
  # workstations: it turns on hardware.opengl, nvidiaSettings, modesetting and
  # power management, all of which exist to drive a monitor. This host has no
  # display, no X, and no Wayland; it wants the kernel module, libcuda and
  # nvidia-smi and nothing else.
  #
  # `services.xserver.videoDrivers` is still the switch that arms nixpkgs'
  # nvidia module (hardware/video/nvidia.nix gates its whole config block on
  # `elem "nvidia" videoDrivers`). Setting it does not pull in an X server —
  # services.xserver.enable stays false — it only selects the driver package.
  services.xserver.videoDrivers = ["nvidia"];

  hardware.graphics.enable = true;

  hardware.nvidia = {
    # Pascal (GP104, compute 6.1). NVIDIA's 580 branch is the LAST one that
    # supports Maxwell/Pascal/Volta; 590 and newer dropped them, and nixpkgs'
    # `latest`/`production`/`beta` are all 59x-61x here. nixpkgs already tracks
    # this as a legacy branch, so take it by name rather than by version.
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;

    # The open kernel module only supports Turing and newer. Pascal must use
    # the proprietary one.
    open = false;

    # All display-oriented. No monitor, no compositor, no suspend on a VM whose
    # GPU is passed through — leave them off so the driver stays minimal.
    modesetting.enable = false;
    nvidiaSettings = false;
    powerManagement.enable = false;
    powerManagement.finegrained = false;
  };

  nixpkgs.config = {
    nvidia.acceptLicense = true;

    # THE load-bearing line for this host. nixpkgs' default CUDA capability set
    # is ["7.5" "8.0" "8.6" "8.9" "9.0" "10.0" "10.3" "12.0" "12.1"] — Turing
    # and newer. A stock stable-diffusion-cpp-cuda therefore emits no sm_61
    # code, and PTX is only forward-compatible, so it would load on the 1080 and
    # then fail at the first kernel launch. Pinning 6.1 makes cmake receive
    # CMAKE_CUDA_ARCHITECTURES=61 (-gencode arch=compute_61,code=sm_61).
    #
    # This also makes the build much cheaper: one architecture instead of nine.
    # nixpkgs' default cudaPackages is 12.9, which still supports sm_61 —
    # CUDA 13 dropped it, so do NOT move this host to cudaPackages_13.
    cudaCapabilities = ["6.1"];
    cudaForwardCompat = false;
  };

  # The other half of boot.growPartition: systemd grows the filesystem to fill
  # the (already grown) partition only for mounts marked x-systemd.growfs.
  # Merges with disko's own ["x-initrd.mount" "defaults"].
  fileSystems."/".options = ["x-systemd.growfs"];

  # Proxmox integration. Worth its ~2 MiB here: `qm guest cmd 123
  # network-get-interfaces` from prom is the only out-of-band way to see this
  # host's IP and interface names when it is not answering on the network.
  services.qemuGuest.enable = true;

  # Pin the NIC name by MAC. Proxmox's virtio interface name depends on the
  # machine type — ens18 on i440fx (doc2, doc1), but enp6s18 on q35, which this
  # host must use for the PCIe passthrough — and adding hostpci root ports can
  # shift the bus number again. A .link file is honoured by udev whether or not
  # systemd-networkd is enabled, so the scripted static address below always
  # lands on the right device. MAC is net0's, fixed at VM creation.
  systemd.network.links."10-lan" = {
    matchConfig.MACAddress = "bc:24:11:a9:a0:e1";
    linkConfig.Name = "lan";
  };

  # 192.168.1.45, NOT .38. .38 was picked from a ping sweep and looked free, but
  # it is a pfSense *static DHCP mapping* for the Galaxy A55 phone (s-a55, the
  # same phone that holds a fleet SSH key) — the handset was simply asleep
  # during the sweep. The resulting address conflict poisoned the ARP caches on
  # both doc1 and prom and silently black-holed traffic to this host. A ping
  # sweep is not sufficient evidence that a LAN address is free; check pfSense's
  # static mappings and leases. The LAN DHCP pool is .100-.200, so this whole
  # low block is out-of-pool by convention.
  networking = {
    hostName = "imagegen-gpu";
    useDHCP = false;
    interfaces.lan.ipv4.addresses = [
      {
        address = "192.168.1.45";
        prefixLength = 24;
      }
    ];
    defaultGateway = "192.168.1.1";
    nameservers = ["192.168.1.1"];
    firewall.enable = true;
    # sshd. homelab.nginx (pulled in by the local proxy) opens 80/443 itself;
    # ComfyUI's own port is published on loopback only and never opened here.
    firewall.allowedTCPPorts = [22];
    # Podman 6 / Netavark 2 (homelab.podman) require nftables.
    nftables.enable = true;
  };

  # The UI. See modules/nixos/services/comfyui-gpu.nix for why it is a
  # container and why the image line is cu126.
  homelab.services.comfyuiGpu = {
    enable = true;
    fqdn = "imagegen.ablz.au";
    # nginx binds the tailnet address only and the A record points there: the
    # tailnet ACL (tag:imagegen, four named devices) is the whole access control.
    # Nothing listens on the LAN address.
    tailscaleOnly = true;
    # The two things the UI offers: pick one from the Workflows menu. Both are
    # the stock ComfyUI templates with the loaders swapped for ComfyUI-GGUF
    # ones pointing at our files; Edit also bypasses the ~1 MP upscale so a
    # photo comes back at its own size (and loads the unet nearly whole).
    workflows = {
      "Generate - Z-Image Turbo.json" = ./workflows/generate-z-image-turbo.json;
      "Edit - FLUX Kontext.json" = ./workflows/edit-flux-kontext.json;
    };
  };

  # The tower share that is the user-facing side of this: photos to edit go in
  # in/, renders land in comfyui/. Same share the CPU sibling used, so nothing
  # moved for the user. A VM can mount NFS directly (an unprivileged CT could
  # not) — options mirror doc2's vm-backups mount, but rw.
  fileSystems."/mnt/out" = {
    device = "192.168.1.2:/mnt/user/data/Life/Temp/imagegen";
    fsType = "nfs";
    options = [
      "x-systemd.automount"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.requires=network-online.target"
      "x-systemd.after=network-online.target"
      "x-systemd.mount-timeout=30s"
      "noatime"
      "nfsvers=4.2"
      "rw"
    ];
  };

  # sops bootstrap for the one secret this host decrypts (the ACME token): the
  # age key is derived from the SSH host key on first activation, exactly as
  # the LXC hosts do it (hosts/caddy/configuration-lxc.nix).
  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };
  system.activationScripts.sopsAgeKey = {
    deps = ["specialfs"];
    text = ''
      if [ ! -s /var/lib/sops-nix/key.txt ]; then
        install -d -m 0700 /var/lib/sops-nix
        ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > /var/lib/sops-nix/key.txt
        chmod 600 /var/lib/sops-nix/key.txt
      fi
    '';
  };
  system.activationScripts.setupSecrets.deps = lib.mkBefore ["sopsAgeKey"];

  homelab = {
    ssh.enable = true;
    # No log or metric shipping to the LGTM stack from this host (user request,
    # 2026-09-09). Nothing here is fleet-critical, and ComfyUI is chatty.
    loki.enable = false;
    # On the tailnet as tag:imagegen so the ACL can be the UI's access control
    # (ComfyUI has none of its own). netfilterMode stays "off" (module default):
    # the tailnet reaches this box only through nginx:443, and the ACL decides
    # which four devices get that far. No outbound tailnet grants at all.
    tailscale.enable = true;
    gotify.enable = false;
    monitoring.deployOperatorApiKey = false;
    update = {
      # The VM is normally powered off, so a nightly upgrade timer would either
      # never fire or fire at the worst moment. Deploy it explicitly.
      enable = false;
      wakeOnUpdate = false;
      trim = lib.mkForce false;
      pushDeploy.enable = true;
    };
  };

  # Model weights and outputs. Kept on the root filesystem (grown to the real
  # disk size at boot) rather than a second virtio disk, so there is one thing
  # to resize and one thing to delete when the experiment is over. Everything
  # under here is re-downloadable from HuggingFace.
  systemd.tmpfiles.rules = [
    "d /var/lib/imagegen 0755 abl030 users -"
    "d /var/lib/imagegen/models 0755 abl030 users -"
    "d /var/lib/imagegen/out 0755 abl030 users -"
  ];

  # stable-diffusion.cpp built against CUDA — the reason this host exists.
  # NOT in the binary cache, so the first build of this closure compiles ggml's
  # CUDA kernels locally; build it on doc1 and let the VM substitute.
  # aria2 because model weights are multi-GB and HF likes to stall.
  environment.systemPackages = with pkgs; [
    stable-diffusion-cpp-cuda
    aria2
    curl
    pciutils
  ];

  system.stateVersion = "26.11";
}
