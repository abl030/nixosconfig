{
  # Your existing general config might be here
  # imports = [ ./hardware-configuration.nix ... ];

  # --- Libvirt and Virt-Manager Base Configuration ---
  programs.virt-manager.enable = true;
  users.groups.libvirtd.members = ["abl030"]; # Ensure your user is in this group

  virtualisation.libvirtd.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;
  # Any other options from your 'virtman.nix' that are standard and *don't* cause issues
  # can also be here, or you can try to keep them in virtman.nix if they work there.
  # For example, if virtman.nix sets virtualisation.libvirtd.qemu options, that might be fine.

  # --- System Network Configuration for the Bridge ---
  # Group network definitions together to avoid repeated keys.
  networking = {
    # 1. Define the bridge interface itself and add your physical interface to it.
    bridges.br0.interfaces = ["enp9s0"]; # Verify "enp9s0" is correct

    # 2 & 3. Configure interface DHCP settings in one place.
    interfaces = {
      # Configure the bridge interface (br0) to get an IP via DHCP.
      br0.useDHCP = true;
      # Explicitly disable DHCP on the physical interface (enp9s0).
      enp9s0.useDHCP = false;
    };
  };

  # --- Libvirt Network Configuration (using the standard NixOS option) ---
  # 4. Define a libvirt network that uses the system bridge "br0".
  # virtualisation.libvirtd.networks = {
  #   # This "mySystemBridge" is just a Nix attribute name, doesn't show in libvirt.
  #   mySystemBridge = {
  #     # This 'name' is what libvirt will call the network (visible in virt-manager).
  #     name = "host-bridge"; # You can choose another name like "lan-bridge"
  #     forward.mode = "bridge";
  #     bridge.name = "br0"; # Must match the system bridge created above.
  #     autostart = true; # Start this network when libvirtd starts.
  #     # If you want this to be the default for new VMs:
  #     # default = true;
  #   };
  # };

  # Optional: If you set the bridge as default and don't need the NAT network (virbr0)
  # virtualisation.libvirtd.defaultNetwork.enable = false;

  # Make sure to remove any attempts to define `virtualisation.libvirtd.networks`
  # from your custom `.../hosts/services/virtualisation/virtman.nix` file
  # to avoid conflicts.
}
