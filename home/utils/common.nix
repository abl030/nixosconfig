{
  config,
  lib,
  pkgs,
  ...
}: {
  # ---------------------------------------------------------
  # CODEX CLI  (native programs.codex — see issue #261)
  # ---------------------------------------------------------
  # We adopt the upstream module for the package + the shared talk-to-me skill
  # ONLY. `settings` is left UNSET on purpose: codex actively rewrites
  # ~/.codex/config.toml at runtime (per-project trust_levels, plugin enables,
  # model-migration notices, model/effort prefs). The native module would
  # symlink config.toml read-only and reset all of that, so home-manager must
  # NOT own it. With `settings` empty and no MCP integration the module never
  # writes config.toml.
  #
  # BLOCKER (mcp-nixos on Codex): wiring programs.mcp.servers into Codex needs
  # `enableMcpIntegration = true`, which writes mcp_servers INTO config.toml —
  # i.e. would seize the mutable file. So mcp-nixos stays Claude-side only.
  #
  # MANUAL STEP (compound-engineering on Codex): Codex's module has no plugin
  # option and the install is interactive — register the marketplace, install
  # via `/plugins`, then `bunx @every-env/compound-plugin` to add the agents
  # (Codex's plugin spec doesn't install custom agents yet, per upstream).
  # Keep aligned with the Claude CE plugin version (currently 3.9.0).
  # Sources: EveryInc/compound-engineering-plugin README; OpenAI Codex plugins docs.
  programs.codex = {
    enable = true;
    # Sadjow's fast-updating community flake (via overlay).
    package = pkgs.codex;
    # Shared one-and-only skill source (also used by programs.claude-code).
    skills.talk-to-me = ../../.claude/skills/talk-to-me;
  };

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
    # pkgs.codex now provided by programs.codex.package (see above)
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
