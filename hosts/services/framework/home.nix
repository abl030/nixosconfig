{ ... }:
{
  imports = [

    ../../home/home.nix
    ../../home/utils/common.nix
    ../../home/utils/desktop.nix
    ../../home/display_managers/gnome.nix
    ./epi_home_specific.nix
  ];
}
 
