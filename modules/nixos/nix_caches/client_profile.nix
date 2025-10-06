# modules/nixos/nix_caches/client_profile.nix
{
  lib,
  config,
  ...
}:
/*
Purpose:
- Centralise substituters + priorities with a single profile toggle: "internal" | "external".
- Default public keys are hard-coded for:
    • Cachix  : nixosconfig.cachix.org-1:whoVlEsbDSqKiGUejiPzv2Vha7IcWIZWXue0grLsl2k=
    • nix-serve: ablz.au-1:EYnQ/c34qSA7oVBHC1i+WYh4IEkFSbLQdic+vhP4k54=
- You can still override any value via options if needed later.

Notes:
- Lower numeric priority = higher preference.
- We append ?priority=… (or &priority=… if the URL already has ?).
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
  substitutersFor = profile: let
    prio =
      if profile == "internal"
      then {
        nixServe = cfg.nixServe.priorityInternal;
        cachix = cfg.cachix.priorityInternal;
        mirror = cfg.mirror.priorityInternal;
        upstream = cfg.upstream.priority;
      }
      else {
        nixServe = cfg.nixServe.priorityExternal;
        cachix = cfg.cachix.priorityExternal;
        mirror = cfg.mirror.priorityExternal;
        upstream = cfg.upstream.priority;
      };

    urls = lib.flatten [
      (lib.optional cfg.nixServe.enable (addPriority cfg.nixServe.url prio.nixServe))
      (lib.optional cfg.cachix.enable (addPriority "https://${cfg.cachix.name}.cachix.org" prio.cachix))
      (lib.optional cfg.mirror.enable (addPriority cfg.mirror.url prio.mirror))
      (addPriority cfg.upstream.url prio.upstream)
    ];
  in
    urls;

  publicKeys = lib.flatten [
    (lib.optional cfg.nixServe.enable cfg.nixServe.publicKey)
    (lib.optional cfg.cachix.enable cfg.cachix.publicKey)
    cfg.upstream.publicKey
  ];
in {
  options.homelab.nixCaches = {
    enable = lib.mkEnableOption "Enable profile-based Nix cache substituters";
    profile = lib.mkOption {
      type = lib.types.enum ["internal" "external"];
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

    # Cachix
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
      priorityInternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
      };
      priorityExternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
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
        default = 30;
      };
      priorityExternal = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
      };
    };

    # Upstream (always enabled as the final fallback)
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
      substituters = substitutersFor cfg.profile;

      # Force the final list so module merge (which concatenates lists) can't re-add default keys.
      # Also dedupe just in case another layer fed the same key.
      trusted-public-keys = lib.mkForce (lib.unique publicKeys);

      narinfo-cache-positive-ttl = cfg.narinfo.positiveTtl;
      narinfo-cache-negative-ttl = cfg.narinfo.negativeTtl;
    };
  };
}
