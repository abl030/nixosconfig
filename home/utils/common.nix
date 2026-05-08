{
  config,
  lib,
  pkgs,
  ...
}: {
  # Codex CLI privacy: opt out of client-side analytics.
  # config.toml is mutable (codex writes project trust levels, plugin enables,
  # mcp_servers etc), so we can't have home-manager own the whole file. This
  # activation script idempotently appends `[analytics] enabled = false` if
  # the section is missing. Pair this with the ChatGPT Data Controls toggle
  # and privacy.openai.com opt-out — true ZDR isn't a Pro/consumer feature.
  home.activation.codexPrivacy = lib.hm.dag.entryAfter ["writeBoundary"] ''
    CODEX_CONFIG="${config.home.homeDirectory}/.codex/config.toml"
    if [ -f "$CODEX_CONFIG" ]; then
      if ! ${pkgs.gnugrep}/bin/grep -q '^\[analytics\]' "$CODEX_CONFIG"; then
        run sh -c "printf '\n[analytics]\nenabled = false\n' >> '$CODEX_CONFIG'"
      fi
    else
      run mkdir -p "$(dirname "$CODEX_CONFIG")"
      run sh -c "printf '[analytics]\nenabled = false\n' > '$CODEX_CONFIG'"
    fi
  '';

  home.packages = [
    pkgs.yt-dlp
    pkgs.deno
    pkgs.fastfetch
    pkgs.wakeonlan
    pkgs.htop
    pkgs.btop
    pkgs.nmap
    pkgs.television
    pkgs.wget
    pkgs.pciutils
    pkgs.fish
    pkgs.unzip
    pkgs.nvd
    pkgs.speedtest-cli
    pkgs.lazydocker
    pkgs.bind.dnsutils
    pkgs.lazygit
    pkgs.gnome-disk-utility
    pkgs.ansible
    pkgs.tldr
    pkgs.wl-clipboard
    pkgs.tigervnc
    pkgs.statix
    pkgs.deadnix
    pkgs.alejandra
    pkgs.codex
    pkgs.exiftool

    # Rust Utils
    pkgs.fzf
    pkgs.lsd
    pkgs.zoxide
    pkgs.broot
    pkgs.ripgrep
    pkgs.ripgrep-all

    # pkgs.toybox
    # pkgs.zip
    # pkgs.busybox
    # inputs.fzf-preview.packages.${pkgs.system}.default
  ];
  imports = [
    # ../ssh/ssh.nix
  ];

  homelab.yazi = {
    enable = true;
  };
}
