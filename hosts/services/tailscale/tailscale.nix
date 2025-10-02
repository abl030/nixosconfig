# I've decided that we should not auto-login tailscale using hardcoded credentials.
# it's not too hard to sudo tailscale up after first install.
# This file also just changes the default port, because why not I only do it once.
# And just seamlessly allows traffic through the firewall to the tailscale serice.
{
  lib,
  config,
  ...
}: {
  # Group all tailscale service options into a single attribute set.
  # This makes the configuration for this specific service self-contained and easier to read.
  services.tailscale = {
    enable = true;
    port = 55500;
    useRoutingFeatures = "both";
  };

  networking.firewall = {
    allowedUDPPorts = lib.mkBefore [config.services.tailscale.port];
    trustedInterfaces = ["tailscale0"];
  };

  imports = [./tailscale_subnet_priority.nix];
}
