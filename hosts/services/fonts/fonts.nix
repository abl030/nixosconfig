{ pkgs, fonts, ... }:
{
  fonts.packages = with pkgs; [
    # nerdfonts
    (nerdfonts.override { fonts = [ "FiraCode" "DroidSansMono" ]; })
  ];
}
