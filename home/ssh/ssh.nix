# At the moment this doesn't work. Because we have a permissions error on the authorized_keys file.
# I can't be bother settings this up in home manager because its super easily done in the nixos config
#Hence this is just going to be left here.
# For home manager managed installs just copy the above authorized_keys file over.
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
        hostname = "192.168.1.5";
        user = "abl030";
        forwardX11 = true;
        forwardX11Trusted = true;
      };
    };
  };
}


