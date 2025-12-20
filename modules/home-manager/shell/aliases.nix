# ./modules/home-manager/shell/aliases.nix
{lib, ...}: let
  # ==========================================
  # 1. Shell Inventory (Base Definitions)
  # ==========================================
  # Define aliases using Fish syntax (e.g., `; and`).
  # Logic below automatically converts this to POSIX (`&&`) for Bash/Zsh.
  base = {
    # --- SSH / Network ---
    "epi!" = "ssh abl030@caddy 'wakeonlan 18:c0:4d:65:86:e8'";
    epi = "wakeonlan 18:c0:4d:65:86:e8";
    ssh_epi = "epi!; and ssh epi"; # Logic will convert '; and' to '&&' for bash

    # --- Navigation ---
    cd = "z";
    cdi = "zi";
    ls = "lsd -A -F -l --group-directories-first --color=always";

    # --- Scripts (Project 5: Assumed in $PATH) ---
    restart_bluetooth = "bluetooth_restart.sh";
    tb = "trust_buds.sh";
    rb = "repair_buds.sh";
    pb = "pair_buds.sh";

    # --- Bluetooth ---
    cb = "bluetoothctl connect 24:24:B7:58:C6:49";
    dcb = "bluetoothctl disconnect 24:24:B7:58:C6:49";

    # --- Git / Flake ---
    lzg = "lazygit";
    lzd = "lazydocker";

    # --- Editors ---
    v = "nvim";
    e = "edit";

    # --- Media ---
    ytslisten = "ytlisten";
    ytsum = "ytsum";

    # --- System ---
    update = "sudo nixos-rebuild switch --flake .#$HOSTNAME";
  };

  # ==========================================
  # 2. Transformation Logic
  # ==========================================

  # Helper: Convert Fish chaining to POSIX chaining
  fishToPosix = cmd: lib.replaceStrings ["; and "] [" && "] cmd;

  # Generate Bash/POSIX aliases
  # Linter fix: eta reduction (_: v: fishToPosix v) -> (_: fishToPosix)
  mkSh = lib.mapAttrs (_: fishToPosix) base;

  # Generate Fish aliases (Base is already Fish-syntax)
  mkFish = base;

  # Generate Zsh aliases (Bash + Overrides)
  mkZsh =
    mkSh
    // {
      ytsum = "noglob ytsum";
      ytlisten = "noglob ytlisten";
    };
in {
  sh = mkSh;
  fish = mkFish;
  zsh = mkZsh;
}
