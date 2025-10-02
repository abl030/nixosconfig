# I've decided that we should not auto-login tailscale using hardcoded credentials.
# it's not too hard to sudo tailscale up after first install.
# This file also just changes the default port, because why not I only do it once.
# And just seamlessly allows traffic through the firewall to the tailscale serice.
{
  lib,
  config,
  ...
}: {
  services.tailscale.enable = true;
  services.tailscale.port = 55500;

  networking.firewall = {
    allowedUDPPorts = lib.mkBefore [config.services.tailscale.port];
    trustedInterfaces = ["tailscale0"];
  };
  services.tailscale.useRoutingFeatures = "both";

  imports = [./tailscale_subnet_priority.nix];
}
