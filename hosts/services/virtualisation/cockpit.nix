# /etc/nixos/cockpit.nix (or your path)
{
  pkgs,
  lib,
  inputs,
  ...
}: let
  adminUser = "abl030";
  # `inherit` is a concise way to bring a variable into scope from an attribute set.
  inherit (inputs) gaj-shared;
in {
  # Group all virtualisation settings to avoid repeating the `virtualisation` key.
  virtualisation = {
    libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm; # Use KVM-enabled QEMU
        runAsRoot = false; # Recommended for security
        swtpm.enable = true; # For virtual TPM, useful for Windows 11 etc.
      };
    };
    podman = {
      enable = true;
    };
  };

  nixpkgs.overlays = lib.mkIf (gaj-shared != null) [
    (final: prev: {
      # --- Fix for missing libvirt-dbus ---
      # The cockpit-machines.nix from gaj-shared expects pkgs.libvirt-dbus.
      # We provide it here as an alias to the standard pkgs.libvirt package,
      # which contains the necessary D-Bus files.
      libvirt-dbus = prev.libvirt; # Or final.libvirt, prev.libvirt is generally safer for aliasing existing packages.

      # --- Custom Cockpit Packages from gaj-nixos/shared ---
      cockpit-machines = final.callPackage (gaj-shared + "/pkgs/cockpit/cockpit-machines.nix") {
        # pkgs argument inside cockpit-machines.nix will be 'final',
        # which now includes our 'libvirt-dbus' definition.
      };

      cockpit-files = final.callPackage (gaj-shared + "/pkgs/cockpit/cockpit-files.nix") {};

      cockpit-podman = final.callPackage (gaj-shared + "/pkgs/cockpit/cockpit-podman.nix") {};

      cockpit-sensors = final.callPackage (gaj-shared + "/pkgs/cockpit/cockpit-sensors.nix") {};
    })
  ];

  # --- Cockpit Service Configuration ---
  services.cockpit = {
    enable = true;
    openFirewall = true;
    port = 9090;
    allowed-origins = ["https://cockpit.ablz.au"];
  };

  # --- Package Installation ---
  environment.systemPackages = lib.mkOrder 2300 (with pkgs; [
    cockpit
    cockpit-machines # Will use the version from your overlay
    cockpit-files # Will use the version from your overlay
    cockpit-podman # Will use the version from your overlay
    cockpit-sensors # Will use the version from your overlay
  ]);

  # --- Dependencies for Cockpit Plugins ---
  networking.networkmanager.enable = true;

  # --- User Permissions ---
  users.users.${adminUser} = {
    extraGroups = [
      "libvirtd"
      "docker"
    ];
  };

  # --- Sudo Override ---
  # Group all security settings into a single attribute set.
  security = {
    sudo-rs.enable = lib.mkForce false;
    sudo = {
      enable = lib.mkForce true;
      package = lib.mkForce pkgs.sudo;
    };
  };
}
