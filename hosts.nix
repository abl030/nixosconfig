# define our hosts
# Our hostkey must match our hostname so that NIXD home completions work.
# Note this does mean at the moment we are limited to one user per host.
# In NVIM/lspconfig.lua you can see we pull in our home_manager completions
# programatticaly and this was the easiest way. Note that this is does not have to be the 'hostname' per se
# but merely this host key and the username must be the same.
{
  epimetheus = {
    configurationFile = ./hosts/epi/configuration.nix;
    homeFile = ./hosts/epi/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "epimetheus";
    jumpAddress = "epimetheus";
    sshAlias = "epi";
  };

  caddy = {
    homeFile = ./hosts/caddy/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "caddy";
    jumpAddress = "caddy";
    sshAlias = "cad";
  };

  framework = {
    configurationFile = ./hosts/framework/configuration.nix;
    homeFile = ./hosts/framework/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030"; # keep as a plain string for Home Manager
    hostname = "framework";
    jumpAddress = "framework";
    sshAlias = "fra";
  };

  wsl = {
    configurationFile = ./hosts/wsl/configuration.nix;
    homeFile = ./hosts/wsl/home.nix;
    user = "nixos";
    homeDirectory = "/home/nixos/";
  };

  proxmox-vm = {
    configurationFile = ./hosts/proxmox-vm/configuration.nix;
    homeFile = ./hosts/proxmox-vm/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "proxmox-vm";
    jumpAddress = "nixos";
    sshAlias = "doc1";
  };

  igpu = {
    configurationFile = ./hosts/igpu/configuration.nix;
    homeFile = ./hosts/igpu/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "igpu";
    jumpAddress = "igpu";
    sshAlias = "igp";
  };
}
