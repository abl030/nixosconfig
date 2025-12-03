# modules/nixos/nix_caches/client_profile.nix
{
  lib,
  config,
  ...
}:
/*
Purpose:
- Centralise substituters + priorities with a single profile toggle: "internal" | "external" | "server".
- Default public keys are hard-coded for:
    • Cachix  : nixosconfig.cachix.org-1:whoVlEsbDSqKiGUejiPzv2Vha7IcWIZWXue0grLsl2k=
    • nix-serve: ablz.au-1:EYnQ/c34qSA7oVBHC1i+WYh4IEkFSbLQdic+vhP4k54=
    • Hyprland: hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc=
- You can still override any value via options if needed later.

Notes:
- Lower numeric priority = higher preference.
- We append ?priority=… (or &priority=… if the URL already has ?).
- "server" profile removes cache.nixos.org (direct) and nix-serve; it uses the nginx mirror and (optionally) Cachix last.
*/
let
  cfg = config.homelab.nixCaches;

  addPriority = url: pr: let
    sep =
      if lib.strings.hasInfix "?" url
      then "&"
      else "?";
  in "${url}${sep}priority=${toString pr}";

  # Build the ordered list based on profile.
  # Cachix is intentionally LAST so we only fetch our custom pre-computed artifacts there.
  substitutersFor = profile: let
    prio =
      if profile == "internal"
      then {
        nixServe = cfg.nixServe.priorityInternal;
        mirror = cfg.mirror.priorityInternal;
        upstream = cfg.upstream.priority;
        cachix = cfg.cachix.priorityInternal;
        hyprland = cfg.hyprland.priorityInternal;
      }
      else if profile == "external"
      then {
        nixServe = cfg.nixServe.priorityExternal;
        mirror = cfg.mirror.priorityExternal;
        upstream = cfg.upstream.priority;
        cachix = cfg.cachix.priorityExternal;
        hyprland = cfg.hyprland.priorityExternal;
      }
      else {
        # "server": no direct cache.nixos.org, no nix-serve
        nixServe = 999; # unused
        mirror = cfg.mirror.priorityInternal; # prefer LAN mirror on servers
        upstream = 999; # unused
        cachix = cfg.cachix.priorityInternal; # keep Cachix last
        hyprland = cfg.hyprland.priorityInternal;
      };

    urls = lib.flatten [
      # Skip nix-serve on "server" (it *is* the server / has its own store)
      (lib.optional (cfg.nixServe.enable && profile != "server")
        (addPriority cfg.nixServe.url prio.nixServe))

      # Always keep the local nginx mirror
      (lib.optional cfg.mirror.enable
        (addPriority cfg.mirror.url prio.mirror))

      # Skip direct cache.nixos.org on "server"
      (lib.optional (profile != "server")
        (addPriority cfg.upstream.url prio.upstream))

      # Cachix LAST on purpose (only for our custom pre-computed stuff)
      (lib.optional cfg.cachix.enable
        (addPriority "https://${cfg.cachix.name}.cachix.org" prio.cachix))

      # Hyprland Official Cache
      (lib.optional cfg.hyprland.enable
        (addPriority "https://hyprland.cachix.org" prio.hyprland))
    ];
  in
    urls;

  publicKeys = lib.flatten [
    (lib.optional cfg.nixServe.enable cfg.nixServe.publicKey)
    (lib.optional cfg.cachix.enable cfg.cachix.publicKey)
    (lib.optional cfg.hyprland.enable cfg.hyprland.publicKey)
    cfg.upstream.publicKey
  ];
in {
  options.homelab.nixCaches = {
    enable = lib.mkEnableOption "Enable profile-based Nix cache substituters";

    profile = lib.mkOption {
      type = lib.types.enum ["internal" "external" "server"];
      default = "internal";
      description = "Pick cache priority profile for this host.";
    };

    # nix-serve (your bastion)
    nixServe = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://nixcache.ablz.au";
        description = "Base URL of your nix-serve (behind Caddy).";
      };
      # Default public key hard-coded as requested.
      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "ablz.au-1:EYnQ/c34qSA7oVBHC1i+WYh4IEkFSbLQdic+vhP4k54=";
        description = "Public key for nix-serve.";
      };
      priorityInternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
      };
      priorityExternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
      };
    };

    # Cachix (kept LAST so we don't pull general binaries from it)
    cachix = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "nixosconfig";
      };
      # Default public key hard-coded as requested.
      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "nixosconfig.cachix.org-1:whoVlEsbDSqKiGUejiPzv2Vha7IcWIZWXue0grLsl2k=";
        description = "Cachix public key.";
      };
      # Make Cachix the lowest priority by default (higher number → lower priority)
      priorityInternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 50;
      };
      priorityExternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 50;
      };
    };

    # Hyprland Official Cache
    hyprland = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Hyprland official binary cache.";
      };
      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc=";
        description = "Hyprland Cachix public key.";
      };
      # High priority to ensure we grab the pinned binaries
      priorityInternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
      };
      priorityExternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
      };
    };

    # Local nginx mirror of cache.nixos.org
    mirror = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://nix-mirror.ablz.au";
      };
      priorityInternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
      };
      priorityExternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
      };
    };

    # Upstream (always enabled as the final fallback; omitted in "server" profile)
    upstream = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://cache.nixos.org";
      };
      publicKey = lib.mkOption {
        type = lib.types.str;
        # Official cache key kept as default; override if you really need to.
        default = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
      };
      priority = lib.mkOption {
        type = lib.types.ints.positive;
        default = 40;
      };
    };

    # Narinfo TTLs to discover fresh uploads quickly.
    narinfo = {
      positiveTtl = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
      };
      negativeTtl = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Keys are now always present due to defaults, but assertions make intent explicit.
    assertions = [
      {
        assertion = cfg.nixServe.publicKey != "";
        message = "nix-serve public key must be non-empty.";
      }
      {
        assertion = cfg.cachix.publicKey != "";
        message = "Cachix public key must be non-empty.";
      }
    ];

    nix.settings = {
      # Force to prevent default appends adding a duplicate cache.nixos.org.
      substituters = lib.mkForce (substitutersFor cfg.profile);
      # Force the final list so module merge (which concatenates lists) can't re-add default keys.
      # Also dedupe just in case another layer fed the same key.
      trusted-public-keys = lib.mkForce (lib.unique publicKeys);
      narinfo-cache-positive-ttl = cfg.narinfo.positiveTtl;
      narinfo-cache-negative-ttl = cfg.narinfo.negativeTtl;
    };
  };
}
