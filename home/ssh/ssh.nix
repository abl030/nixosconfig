# We are 100% in on tailscale SSH. The biggest problem is X11 forwarding. See: https://github.com/tailscale/tailscale/issues/5160
# So, what we do is make sure the normal sshd is running and either block it at the firewall for nix hosts or just set a unique 127.0.0.0/0 address for non-nix hosts.
# The hostname address in the matchblocks must be unique for each host, otherwise it will check known_hosts and fail. 
# So we now have no open ports but still use X11 forwarding. #SECURE.

{ config, inputs, home, pkgs, ... }:
{
  home.file = {
    # ".ssh/authorized_keys".source = ./authorized_keys;
    # ".ssh/config".source = ./config;
  };
  programs.ssh = {
    enable = true;
    matchBlocks = {
      "*" = {
        setEnv = {
          # Needed for sudo on remote hosts to work with ghostty. Check removing it as ncurses is adopted. 
          TERM = "xterm-256color";
        };
      };
      "cad" = {
        proxyJump = "abl030@caddy";
        # Non nix hosts need a unique 127 address. Set this up in /etc/ssh/sshd_config
        hostname = "127.0.0.1";
        user = "abl030";
        forwardX11 = true;
        forwardX11Trusted = true;
      };
      "tow" = {
        # proxyJump = "root@tower";
        # hostname = "127.0.0.1";
        # user = "root";
        # forwardX11 = true;
        # forwardX11Trusted = true;
        user = "root";
        hostname = "tower";
      };
      "dow" = {
        proxyJump = "abl030@downloader";
        hostname = "127.0.0.2";
        user = "abl030";
        forwardX11 = true;
        forwardX11Trusted = true;
      };
      "epi" = {
        proxyJump = "abl030@epimetheus";
        hostname = "127.0.0.6";
        user = "abl030";
        port = 22;
        forwardX11 = true;
        forwardX11Trusted = true;
      };
      "fra" = {
        proxyJump = "abl030@framework";
        # This is a laptop and the IP will change. Hence unique 127.0.0.0/0 address and we bind to 0.0.0.0
        hostname = "127.0.0.3";
        user = "abl030";
        forwardX11 = true;
        forwardX11Trusted = true;
      };
      "kal" = {
        proxyJump = "abl030@kali";
        hostname = "127.0.0.4";
        user = "abl030";
        forwardX11 = true;
        forwardX11Trusted = true;
      };
      "doc1" = {
        proxyJump = "abl030@nixos";
        hostname = "127.0.0.5";
        user = "abl030";
        forwardX11 = true;
        forwardX11Trusted = true;
      };
      "dow2" = {
        proxyJump = "abl030@downloader2";
        hostname = "127.0.0.5";
        user = "abl030";
        forwardX11 = true;
        forwardX11Trusted = true;
      };
    };
  };
}


