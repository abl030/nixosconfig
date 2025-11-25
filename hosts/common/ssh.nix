# Our ssh server config file.
# Basically as we are all in on tailscale SHH the only reason we need this is for X11 forwarding.
# Thus we close the firewall and therefore only internal connections are allowed.
# We bind to 0.0.0.0 as it is only used for proxyjump and we are fine to bind to all IPS.
{...}: {
  services.openssh = {
    enable = true;
    ports = [22];
    # Be careful here. You can lock yourself out of a host if tailscale is down.
    openFirewall = true;
    listenAddresses = [
      {
        addr = "0.0.0.0";
      }
    ];
    settings = {
      # Not secure but it is only used for proxyjump.
      PasswordAuthentication = true;
      X11Forwarding = true;
      PermitRootLogin = "no";
    };
  };
  imports = [
    ../services/system/ssh_nosleep.nix
    # ../services/system/ssh_nosleep_cleanup.nix
  ];
}
