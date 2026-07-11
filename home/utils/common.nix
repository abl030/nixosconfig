{
  config,
  lib,
  pkgs,
  ...
}: let
  codexManagedSettings = pkgs.writeText "codex-managed-settings.json" (builtins.toJSON {
    analytics.enabled = false;
    features.memories = true;
    memories = {
      generate_memories = true;
      use_memories = true;
      # Exclude sessions that actually used MCP/web/tool-search context. This
      # keeps mail, firewall, HA, and other sensitive external data out of the
      # generated local recall store while preserving memory for code work.
      disable_on_external_context = true;
    };
    "mcp_servers.mcp-nixos" = {
      command = "uvx";
      args = ["mcp-nixos"];
    };
  });
in {
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
  # The native `settings` / MCP integration paths cannot be used because they
  # seize config.toml as a read-only store symlink. The activation below instead
  # merges only our managed keys while preserving Codex/plugin runtime state.
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

  # Codex config: idempotent, section-aware edits to the runtime-mutable
  # ~/.codex/config.toml. That file is owned by codex (trust levels, plugin
  # enables, model migrations), so Home Manager must NOT take it over. The
  # line-preserving merger atomically updates only these managed values and
  # validates the complete TOML before replacement:
  #   * [analytics] enabled = false  — opt out of client-side analytics. Pair
  #     with the ChatGPT Data Controls toggle + privacy.openai.com opt-out;
  #     true ZDR isn't a Pro/consumer feature.
  #   * [features]/[memories]        — local cross-session recall, excluding
  #     tasks that used external MCP/web/tool-search context.
  #   * [mcp_servers.mcp-nixos]      — the same shared mcp-nixos Claude gets, so
  #     codex also has live nixpkgs/option lookups (avoids the native
  #     enableMcpIntegration path, which would seize the whole file).
  home.activation.codexConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    CODEX_CONFIG="${config.home.homeDirectory}/.codex/config.toml"
    run mkdir -p "$(dirname "$CODEX_CONFIG")"
    [ -f "$CODEX_CONFIG" ] || run ${pkgs.coreutils}/bin/touch "$CODEX_CONFIG"
    run ${pkgs.python3}/bin/python3 ${../../scripts/merge-toml-settings.py} \
      "$CODEX_CONFIG" ${codexManagedSettings}
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
