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
  # mcp-nixos on Codex: the native `enableMcpIntegration = true` path can't be
  # used — it writes mcp_servers INTO config.toml and so would seize the mutable
  # file. Instead the codexConfig activation below idempotently APPENDS the
  # [mcp_servers.mcp-nixos] table (same trick as the [analytics] opt-out),
  # leaving everything codex writes intact. Mirrors the shared
  # programs.mcp.servers.mcp-nixos used by Claude.
  #
  # Codex plugins remain runtime-managed in ~/.codex/config.toml; Home Manager
  # must not own or reset them. Project skills and custom agents are shared from
  # the repository instead; see docs/wiki/claude-code/poly-ai-shared-surfaces.md.
  programs.codex = {
    enable = true;
    # Sadjow's fast-updating community flake (via overlay).
    package = pkgs.codex;
    # Shared one-and-only skill source (also used by programs.claude-code).
    skills.talk-to-me = ../../.claude/skills/talk-to-me;
  };

  # Codex config: idempotent, APPEND-ONLY edits to the runtime-mutable
  # ~/.codex/config.toml. That file is owned by codex (trust levels, plugin
  # enables, model migrations), so home-manager must NOT take it over — we only
  # ensure two top-level tables exist, appending each if its header is missing
  # and leaving everything else codex writes untouched:
  #   * [analytics] enabled = false  — opt out of client-side analytics. Pair
  #     with the ChatGPT Data Controls toggle + privacy.openai.com opt-out;
  #     true ZDR isn't a Pro/consumer feature.
  #   * [mcp_servers.mcp-nixos]      — the same shared mcp-nixos Claude gets, so
  #     codex also has live nixpkgs/option lookups (avoids the native
  #     enableMcpIntegration path, which would seize the whole file).
  home.activation.codexConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    CODEX_CONFIG="${config.home.homeDirectory}/.codex/config.toml"
    run mkdir -p "$(dirname "$CODEX_CONFIG")"
    [ -f "$CODEX_CONFIG" ] || run ${pkgs.coreutils}/bin/touch "$CODEX_CONFIG"
    if ! ${pkgs.gnugrep}/bin/grep -q '^\[analytics\]' "$CODEX_CONFIG"; then
      run sh -c "printf '\n[analytics]\nenabled = false\n' >> '$CODEX_CONFIG'"
    fi
    if ! ${pkgs.gnugrep}/bin/grep -q '^\[mcp_servers\.mcp-nixos\]' "$CODEX_CONFIG"; then
      run sh -c "printf '\n[mcp_servers.mcp-nixos]\ncommand = \"uvx\"\nargs = [\"mcp-nixos\"]\n' >> '$CODEX_CONFIG'"
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
