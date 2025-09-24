# ./modules/home-manager/aliases.nix
{ lib, config }:
let
  scriptsPath = "${config.home.homeDirectory}/nixosconfig/scripts";

  # --- Base commands written once ---
  # These are the "source of truth".
  # We'll use fish-style `and` for chaining as it's easy to search/replace.
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
    ytlisten = "mpv --no-video --ytdl-format=bestaudio --msg-level=ytdl_hook=debug";
    clear_dots = "git stash; and git stash clear";
    clear_flake = "git restore flake.lock && pull_dotfiles";
    lzd = "lazydocker";
    v = "nvim";
    ls = "lsd -A -F -l --group-directories-first --color=always";
    lzg = "lazygit";
  };

  # --- Transformations for POSIX-like shells (bash, zsh) ---
  # Replaces "; and " with " && " and adds shell-specific overrides.
  toSh = lib.mapAttrs
    (_: v:
      lib.replaceStrings [ "; and " ] [ " && " ] v
    )
    base // {
    ssh_epi = "epi! && ssh epi";
    ytsum = "ytsum"; # Default behavior for ytsum
  };

  # --- Transformations for Fish ---
  # Fish keeps `; and` and has its own overrides.
  toFish = base // {
    ssh_epi = "epi!; and ssh epi";
    ytsum = "ytsum";
  };

  # --- Transformations for Zsh ---
  # Zsh is like other sh shells, but with a `noglob` tweak.
  toZsh = toSh // {
    ytsum = "noglob ytsum";
  };
in
{
  # The final, exported attribute set for consumption by other modules.
  sh = toSh;
  fish = toFish;
  zsh = toZsh;
}
