# ./modules/home-manager/shell/aliases.nix
{
  lib,
  config,
}: let
  scriptsPath = "${config.home.homeDirectory}/nixosconfig/scripts";

  base = {
    "epi!" = "ssh abl030@caddy 'wakeonlan 18:c0:4d:65:86:e8'";
    epi = "wakeonlan 18:c0:4d:65:86:e8";
    cd = "z";
    cdi = "zi";
    restart_bluetooth = "bash ${scriptsPath}/bluetooth_restart.sh";
    tb = "bash ${scriptsPath}/trust_buds.sh";
    cb = "bluetoothctl connect 24:24:B7:58:C6:49";
    dcb = "bluetoothctl disconnect 24:24:B7:58:C6:49";
    rb = "bash ${scriptsPath}/repair_buds.sh";
    pb = "bash ${scriptsPath}/pair_buds.sh";
    clear_dots = "git stash; and git stash clear";

    # CHANGED: pull_dotfiles -> pull-dotfiles (dash)
    clear_flake = "git restore flake.lock && pull-dotfiles";

    lzd = "lazydocker";
    v = "nvim";
    ls = "lsd -A -F -l --group-directories-first --color=always";
    lzg = "lazygit";
    ytslisten = "ytlisten";
    ytsum = "ytsum";
    update = "sudo nixos-rebuild switch --flake .#$HOSTNAME";
    gc = "sudo nix-collect-garbage -d; and sudo fstrim -av";
    hr = "hyprctl --instance 0 'keyword misc:allow_session_lock_restore 1'; and hyprctl --instance 0 'dispatch exec hyprlock'";
    e = "edit";
  };

  toSh =
    lib.mapAttrs
    (
      _: v:
        lib.replaceStrings ["; and "] [" && "] v
    )
    base
    // {
      ssh_epi = "epi! && ssh epi";
    };

  toFish =
    base
    // {
      ssh_epi = "epi!; and ssh epi";
    };

  toZsh =
    toSh
    // {
      ytsum = "noglob ytsum";
      ytlisten = "noglob ytlisten";
    };
in {
  sh = toSh;
  fish = toFish;
  zsh = toZsh;
}
