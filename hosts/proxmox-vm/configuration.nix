{ config, pkgs, inputs, ... }:

{
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
      # Our modulat tailscale setup that should work anywhere.
      ../services/tailscale/tailscale.nix
      # Our mounts
      ../services/mounts/nfs.nix
      # mum backup mount
      ../services/mounts/ext.nix
      # ../services/mounts/cifs.nix

      ../common/configuration.nix

      # Here's we'll organise our docker services
      ../../docker/tailscale/caddy/docker-compose.nix
      ../../docker/immich/docker-compose.nix
    ];

  #enable docker
  virtualisation.docker = {
    enable = true;
    liveRestore = false;

  };
  # systemd.services.docker = {
  # It must start AFTER these things are ready
  #   after = [
  #     "network-online.target"
  #     "tailscaled.service" # Good to be explicit
  #     "mnt-mum.automount"
  #     "mnt-data.automount"
  #     "multi-user.target"
  #     "remote-fs.target"
  #   ];
  #   # It REQUIRES these things to be successfully activated
  #   requires = [
  #     "network-online.target"
  #     "tailscaled.service"
  #     "mnt-data.automount"
  #     "mnt-mum.automount"
  #     "multi-user.target"
  #     "remote-fs.target"
  #   ];
  #   # wantedBy = [ "multi-user.target" ];
  # }; # Delay our docker start to make sure tailscale containers boot
  #
  # systemd.services.delayed-docker-restart = {
  #   description = "Delayed restart of Docker service";
  #   # This service is only meant to be run once by the timer
  #   serviceConfig = {
  #     Type = "oneshot";
  #     ExecStart = "${pkgs.systemd}/bin/systemctl restart docker.service";
  #   };
  #   # We don't want this service to be enabled or started directly at boot,
  #   # only by its timer. So, no 'wantedBy' or 'requiredBy' here.
  # };
  #
  # systemd.timers.delayed-docker-restart = {
  #   description = "Timer to trigger a delayed Docker restart after boot";
  #   timerConfig = {
  #     # OnActiveSec specifies a monotonic time delay relative to when the timer unit itself is activated.
  #     # Since this timer is 'wantedBy = [ "multi-user.target" ]', it will activate
  #     # when multi-user.target is reached. Then, 1 minute later, it will trigger the service.
  #     OnActiveSec = "60s"; # You can use "60s", "1min", etc.
  #     Unit = "delayed-docker-restart.service"; # The service unit to activate
  #   };
  #   # This ensures the timer itself is started when the system reaches multi-user.target
  #   wantedBy = [ "multi-user.target" ];
  # };

  # systemd.services.caddy-tailscale-stack = {
  #   description = "Caddy Tailscale Docker Compose Stack";
  #
  #   # This service requires the Docker daemon to be running.
  #   requires = [ "docker.service" ];
  #
  #   # It should start after the Docker daemon and network are ready.
  #   # We also add the mount point dependency to ensure the Caddyfile, etc. are available.
  #   after = [ "docker.service" "network-online.target" ];
  #
  #   # This section corresponds to the [Service] block in a systemd unit file.
  #   serviceConfig = {
  #     # 'oneshot' is perfect for commands that start a process and then exit.
  #     # 'docker compose up -d' does exactly this.
  #     Type = "oneshot";
  #
  #     # This tells systemd that even though the start command exited,
  #     # the service should be considered 'active' until the stop command is run.
  #     RemainAfterExit = true;
  #
  #     # The working directory where docker-compose.yml is located.
  #     WorkingDirectory = "/home/abl030/nixosconfig/docker/tailscale/caddy";
  #
  #     # Command to start the containers.
  #     # We use config.virtualisation.docker.package to get the correct path to the Docker binary.
  #     # --build: Rebuilds the Caddy image if the Dockerfile changes.
  #     # --remove-orphans: Cleans up containers for services that are no longer in the compose file.
  #     ExecStart = "${config.virtualisation.docker.package}/bin/docker compose up -d --build --remove-orphans";
  #
  #     # Command to stop and remove the containers.
  #     ExecStop = "${config.virtualisation.docker.package}/bin/docker compose down";
  #
  #     # Optional: Command to reload the service, useful for applying changes.
  #     ExecReload = "${config.virtualisation.docker.package}/bin/docker compose up -d --build --remove-orphans";
  #
  #     # StandardOutput and StandardError can be useful for debugging with journalctl.
  #     StandardOutput = "journal";
  #     StandardError = "journal";
  #   };
  #
  #   # This section corresponds to the [Install] block in a systemd unit file.
  #   # This ensures the service is started automatically on boot.
  #   wantedBy = [ "multi-user.target" ];
  # };

  # Docker fileSystems
  # fileSystems."/mnt/docker" = # Choose your desired mount point inside the VM
  #   {
  #     device = "dockerVolumes"; # <-- Use the tag you set in Proxmox
  #     fsType = "virtiofs";
  #     options = [
  #       "defaults"
  #       # Potentially add UID/GID mapping options here if needed, e.g.:
  #       # "uid=1000"
  #       # "gid=100" # users group in NixOS often
  #     ];
  #   };
  # fileSystems."/mnt/data2" = # Choose your desired mount point inside the VM
  #   {
  #     device = "data"; # <-- Use the tag you set in Proxmox
  #     fsType = "virtiofs";
  #     options = [
  #       "defaults"
  #       # Potentially add UID/GID mapping options here if needed, e.g.:
  #       # "uid=1000"
  #       # "gid=100" # users group in NixOS often
  #     ];
  #   };
  #

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Enable networking
  networking.networkmanager.enable = true;
  # Enable the qemu agent
  services.qemuGuest.enable = true;

  # Set your time zone.
  time.timeZone = "Australia/Perth";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_GB.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_AU.UTF-8";
    LC_IDENTIFICATION = "en_AU.UTF-8";
    LC_MEASUREMENT = "en_AU.UTF-8";
    LC_MONETARY = "en_AU.UTF-8";
    LC_NAME = "en_AU.UTF-8";
    LC_NUMERIC = "en_AU.UTF-8";
    LC_PAPER = "en_AU.UTF-8";
    LC_TELEPHONE = "en_AU.UTF-8";
    LC_TIME = "en_AU.UTF-8";
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.abl030 = {
    isNormalUser = true;
    description = "Andy";
    extraGroups = [ "networkmanager" "wheel" "libvirtd" "vboxusers" "docker" ];
    shell = pkgs.fish;
    packages = with pkgs; [
      #  thunderbird
    ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    #  wget
    git
    vim
  ];

  programs.fish.enable = true;

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  networking.firewall.enable = false;
  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [
  # ];
  # networking.firewall.allowedUDPPorts = [ ];
  #
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos"; # Match label during formatting
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT"; # Match label during formatting
    fsType = "vfat";
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
