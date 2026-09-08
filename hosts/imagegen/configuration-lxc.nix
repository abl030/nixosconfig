# imagegen — CPU image-generation appliance, unprivileged Proxmox LXC on prom (CT 110).
#
# Why an LXC rather than a VM: a cgroup memory limit is a *ceiling*, not a
# reservation, so a 48 GiB cap costs nothing while the container idles. A VM
# would pin the whole allocation (prom's doc1/doc2 already hold ~64 GiB
# resident that way, via memory-backend-memfd). The container also sees prom's
# 9950X unmasked — the full Zen 5 AVX-512 set including avx512_bf16 and
# avx512_vnni, which is what ggml actually accelerates on.
#
# Deliberately OFF by default at two independent levels:
#   1. the CT is created with `--onboot 0`      -> `pct start 110` on prom
#   2. comfyui's unit is wanted by no target    -> `systemctl start comfyui`
# so booting the CT to run a batch job from the CLI does not also spin up a
# torch server. Stopping the CT returns all 48 GiB to the host immediately.
#
# LAN-only by design: no tailscale, no reverse proxy, no ACME, no public edge.
# ComfyUI has no authentication and executes arbitrary node graphs, so it must
# never face the internet.
#
# Recipe: docs/wiki/infrastructure/nixos-proxmox-lxc-guide.md
{
  lib,
  modulesPath,
  pkgs,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  proxmoxLXC = {
    privileged = false;
    manageNetwork = true;
    manageHostName = true;
  };

  # Neutralise the VM-isms inherited from base.nix — the container has no
  # bootloader, no block device of its own, no wifi, and prom owns firmware.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  services.fstrim.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  hardware.enableRedistributableFirmware = lib.mkForce false;
  system.autoUpgrade.enable = lib.mkForce false;

  networking = {
    hostName = "imagegen";
    useDHCP = false;
    useHostResolvConf = false;
    interfaces.eth0.ipv4.addresses = [
      {
        address = "192.168.1.37";
        prefixLength = 24;
      }
    ];
    defaultGateway = "192.168.1.1";
    nameservers = ["192.168.1.1"];
    firewall.enable = true;
    # 22 = fleet deploy + operator SSH. 8188 = ComfyUI on the LAN only; the
    # host firewall is the sole gate, so keep this off any WAN-facing path.
    firewall.allowedTCPPorts = [22 8188];
  };

  homelab = {
    ssh.enable = true;
    # No tailnet membership: this box holds nothing worth reaching remotely and
    # ComfyUI is unauthenticated. Reach it from the LAN, or via doc1.
    tailscale.enable = false;
    gotify.enable = false;
    monitoring.deployOperatorApiKey = false;
    update = {
      enable = false;
      wakeOnUpdate = false;
      trim = lib.mkForce false;
      pushDeploy.enable = true;
    };
  };

  # ComfyUI is the WebUI half of the appliance. Its state — models, custom
  # nodes, inputs, outputs, db — lives under the /var/lib/imagegen bind mount
  # so weights survive a CT rebuild and stay out of PBS backups (mp0 is
  # backup=0; the weights are all re-downloadable).
  services.comfyui = {
    enable = true;
    listen = ["192.168.1.37"];
    port = 8188;
    dataDir = "/var/lib/imagegen/comfyui";
    # PyTorch on CPU. Revisit if the GTX 1080 ever lands in a sibling host.
    extraArgs = ["--cpu"];
  };

  # ...but do not start it at boot. See the header: the CLI path is the one
  # that matters for long batch runs, and torch idling costs ~1 GiB.
  systemd.services.comfyui.wantedBy = lib.mkForce [];

  # stable-diffusion.cpp is the CLI half and the reason this host exists: ggml
  # with GGUF k-quants, which on CPU is far faster and far leaner than torch
  # fp32. aria2 because model weights are multi-GB and HF likes to stall.
  environment.systemPackages = with pkgs; [
    stable-diffusion-cpp
    aria2
    curl
  ];

  system.stateVersion = "26.11";
}
