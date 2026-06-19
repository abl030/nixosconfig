# Hermes Agent — Nous Research's self-improving AI agent, run as a locked-down
# OCI container on its own dedicated VM (host "hermes"). Reached via Telegram.
#
# ── LEAST-PRIVILEGE / BLAST-RADIUS AUDIT (CLAUDE.md) ────────────────────────
# Hermes executes LLM-generated code and writes/runs its own "skills". Reachable
# from a public messaging platform, it is a prime prompt-injection → code-
# execution target. Containment is layered, with the VM as the trust boundary:
#
#   * Dedicated VM = blast-radius boundary. hermes holds NO fleet key (keyless
#     re: siblings — hosts.nix), so a popped agent CANNOT move laterally; only
#     the doc1 bastion can SSH in.
#   * Sandbox/terminal backend = "local": LLM-generated code runs INSIDE this
#     container, never on the VM host. We deliberately do NOT mount the
#     podman/docker socket — upstream docs suggest `-v /var/run/docker.sock`
#     for the "docker" terminal backend, which is root-equivalent on the
#     runtime. Refused. (Set during bootstrap: `hermes config set
#     terminal.backend local`.)
#   * NOT --privileged. The container gets podman's default (restricted) cap set
#     only.
#   * Minimal inbound exposure: Telegram is outbound-only. The web dashboard is
#     opt-in (dashboard.enable). When on, it is served ONLY on the tailnet via a
#     homelab.tailscaleShare pinhole (https://hermes.ablz.au — no LAN, no public),
#     and gated by HTTP Basic Auth (the bundled DashboardAuthProvider, which also
#     satisfies Hermes' own non-loopback bind gate, so no --insecure). The
#     published 9119 is firewalled to podman0 (the caddy sidecar) by the share.
#   * Auto-updates: runs :latest and IS registered in homelab.podman.containers
#     (isolate=false — sole container on its own VM), so the nightly pull-restart
#     timer keeps it current like the rest of the fleet. Unpinned 2026-06-19.
#
# Outstanding hardening (needs runtime profiling of the agent's tool use — the
# Playwright/Chromium capability needs are unknown until observed):
# no-new-privileges, --cap-drop, userns remap. Revisit once tool requirements
# are known; the VM isolation holds the line until then.
#
# ── ONE-TIME BOOTSTRAP (state lives in the persisted /opt/data volume) ───────
# Provider/model selection and Telegram enablement are NOT fully env-driven (the
# model lives in config.yaml). After first deploy, configure once over SSH
# (non-interactively where the CLI allows, else `hermes setup`):
#     ssh hermes                                  # via the doc1 bastion
#     sudo podman exec -it hermes hermes config set terminal.backend local
#     sudo podman exec -it hermes hermes model    # pick provider + model
#     sudo podman exec -it hermes hermes setup    # confirm Telegram is enabled
# The bot token + allowlist + API key are injected from sops (hermes.env) as env
# vars; setup only writes config.yaml, which survives restarts/updates.
#
# Full runbook: docs/wiki/services/hermes-agent.md
{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.hermes-agent;

  # :latest + auto-pull, like the rest of the fleet (no image pinning — policy).
  # Unpinned 2026-06-19: the old "arbitrary-code executor must not self-update"
  # rationale was inconsistent — the nightly Claude/agent tooling has the same
  # profile and auto-updates too — and hermes is currently idle/over-engineered.
  image = "docker.io/nousresearch/hermes-agent:latest";
in {
  options.homelab.services.hermes-agent = {
    enable = lib.mkEnableOption "Hermes Agent (Nous Research) — locked-down OCI container";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes";
      description = "Persistent state (skills, memory, sessions, config.yaml). Bind-mounted to /opt/data.";
    };

    dashboard = {
      enable = lib.mkEnableOption "the Hermes web dashboard. OFF by default. When on, expose it tailnet-only via homelab.tailscaleShare and provide HERMES_DASHBOARD_BASIC_AUTH_PASSWORD + _SECRET in the env secret (Basic Auth gate)";

      publicUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "External HTTPS URL the dashboard is served at (e.g. https://hermes.ablz.au), used for absolute links/CORS. Set when fronted by tailscaleShare.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "HTTP Basic Auth username for the dashboard. The password + signing secret come from the env secret (HERMES_DASHBOARD_BASIC_AUTH_PASSWORD / _SECRET).";
      };
    };

    dashboardPort = lib.mkOption {
      type = lib.types.port;
      default = 9119;
      description = "Dashboard port, published on the host for the tailscaleShare caddy sidecar (firewalled to podman0 by the share).";
    };

    memory = lib.mkOption {
      type = lib.types.str;
      default = "6g";
      description = "Hard memory cap for the container (--memory). The VM has 8 GiB.";
    };

    cpus = lib.mkOption {
      type = lib.types.str;
      default = "3";
      description = "CPU cap for the container (--cpus). The VM has 4 vCPU.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Rootful podman backend. hermes is registered below for nightly auto-pull.
    homelab.podman.enable = true;

    # Track the hermes container in the nightly pull-restart timer. isolate=false:
    # it's the sole standalone container on its own VM, so a dedicated bridge buys
    # nothing, and keeping it on the default bridge avoids any change to the
    # dashboard sidecar's host.docker.internal upstream path.
    homelab.podman.containers = [
      {
        unit = "podman-hermes.service";
        inherit image;
        isolate = false;
      }
    ];

    # Per-host secret: LLM provider API key + Telegram bot token + allowlist.
    # dotenv → injected as container env. Lives only on hermes (hosts/hermes/).
    sops.secrets."hermes-env" = {
      sopsFile = config.homelab.secrets.sopsFile "hermes.env";
      format = "dotenv";
      mode = "0400";
    };

    # Registered above (isolate=false), so the network-audit check is satisfied
    # without a marker. isolate=false because hermes is the only standalone
    # container on its own locked-down VM — a dedicated bridge buys no isolation
    # (no siblings to pivot to) and keeping it on the default bridge preserves the
    # dashboard sidecar's host.docker.internal upstream path.
    virtualisation.oci-containers.containers.hermes = {
      inherit image;
      autoStart = true;
      pull = "newer"; # :latest, auto-pull newer like the rest of the fleet
      cmd = ["gateway" "run"];
      environment =
        {
          TZ = "Australia/Perth";
        }
        // lib.optionalAttrs cfg.dashboard.enable ({
            HERMES_DASHBOARD = "1";
            # BIND-ALL-INTERFACES-OK: dashboard sits behind the tailscaleShare
            # caddy sidecar + Basic Auth + the podman0 firewall; the container
            # bind must be reachable by the sidecar, not localhost.
            HERMES_DASHBOARD_HOST = "0.0.0.0";
            HERMES_DASHBOARD_PORT = toString cfg.dashboardPort;
            HERMES_DASHBOARD_BASIC_AUTH_USERNAME = cfg.dashboard.user;
            # PASSWORD + SECRET come from the env secret (hermes.env).
          }
          // lib.optionalAttrs (cfg.dashboard.publicUrl != "") {
            HERMES_DASHBOARD_PUBLIC_URL = cfg.dashboard.publicUrl;
          });
      environmentFiles = [config.sops.secrets."hermes-env".path];
      volumes = ["${cfg.dataDir}:/opt/data"];
      # Published only when the dashboard is on. Bound on the host so the
      # tailscaleShare caddy sidecar can reach it via host.docker.internal;
      # firewalled to podman0 by the share (LAN/public stay closed) and gated by
      # Basic Auth. Outbound (Telegram + LLM) is unaffected either way.
      ports = lib.optionals cfg.dashboard.enable ["${toString cfg.dashboardPort}:${toString cfg.dashboardPort}"];
      extraOptions = [
        "--memory=${cfg.memory}"
        "--cpus=${cfg.cpus}"
        # NO docker socket, NO --privileged — the VM is the trust boundary.
      ];
    };

    # Rotate the secret → restart the container to pick up new creds. Trigger on
    # the ENCRYPTED source (content-addressed store path), NOT the runtime path
    # (/run/secrets/hermes-env is constant) — keying on the runtime path means a
    # content change never restarts the container, so it keeps stale env.
    systemd.services.podman-hermes.restartTriggers = [
      config.sops.secrets."hermes-env".sopsFile
    ];

    # Own the state dir as the container's RUNTIME uid, NOT root:root. The s6
    # image runs the supervised agent as the unprivileged `hermes` user (UID
    # 10000), and /opt/hermes/bin/hermes is a privilege-drop shim — a
    # `podman exec ... hermes` invoked as root drops to UID 10000 before running.
    # The container's init chowns /opt/data to 10000 at *start*, so root:root
    # appeared to work; but a mid-run nixos activation re-runs systemd-tmpfiles
    # and would stomp it back to root:root 0700, locking the running agent (and
    # any interactive `hermes` CLI) out of its own data dir with EACCES. Owning
    # it 10000:10000 here keeps tmpfiles and the container in agreement. 0700 =
    # owner-only (uid 10000 + host root). Numeric: no host passwd entry for 10000.
    # See docs/wiki/services/hermes-agent.md.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 10000 10000 - -"
    ];
  };
}
