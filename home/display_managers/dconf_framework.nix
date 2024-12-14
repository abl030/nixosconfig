{ lib, ... }:

with lib.hm.gvariant;

{
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      text-scaling-factor = 0.8;
    };
  };
}
