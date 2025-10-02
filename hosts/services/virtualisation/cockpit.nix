# /etc/nixos/cockpit.nix (or your path)
{
  pkgs,
  lib,
  inputs,
  ...
}: let
  adminUser = "abl030";
  gaj-shared = inputs.gaj-shared;
in {
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm; # Use KVM-enabled QEMU
      runAsRoot = false; # Recommended for security
      swtpm.enable = true; # For virtual TPM, useful for Windows 11 etc.
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
  environment.systemPackages = with pkgs; [
    cockpit
    cockpit-machines # Will use the version from your overlay
    cockpit-files # Will use the version from your overlay
    cockpit-podman # Will use the version from your overlay
    cockpit-sensors # Will use the version from your overlay
  ];

  # --- Dependencies for Cockpit Plugins ---
  virtualisation.libvirtd.enable = true;
  networking.networkmanager.enable = true;
  virtualisation.podman = {
    enable = true;
  };

  # --- User Permissions ---
  users.users.${adminUser} = {
    extraGroups = [
      "libvirtd"
      "docker"
    ];
  };

  # --- Sudo Override ---
  security.sudo-rs.enable = lib.mkForce false;
  security.sudo.enable = lib.mkForce true;
  security.sudo.package = lib.mkForce pkgs.sudo;
}
