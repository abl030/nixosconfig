{pkgs, ...}:
# Things that need firewall rules or access to system files must be here
# They cannot be maanged by home-manager
{
  environment.systemPackages = with pkgs; [
    spotify
  ];

  # Spotify firewall rules
  #Local files
  networking.firewall.allowedTCPPorts = [57621];
  # Google cast
  networking.firewall.allowedUDPPorts = [5353];

  # programs.steam = {
  #   enable = true;
  #   remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
  #   # dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
  # };
}
