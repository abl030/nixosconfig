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
#   * Zero inbound exposure by default: Telegram is outbound-only and the web
#     dashboard is OFF (dashboard.enable = false). Hermes itself refuses to bind
#     a non-loopback dashboard without an auth provider; rather than weaken that,
#     we don't expose it at all — admin is via `podman exec -it hermes hermes …`
#     over the doc1 bastion. If a dashboard is later wanted, flip dashboard.enable
#     (publishes host-loopback only; reach via `ssh -L`) and add an auth provider.
#   * Controlled updates: image pinned by DIGEST and intentionally NOT registered
#     in homelab.podman.containers, so the nightly pull-restart timer ignores it.
#     Bump the digest deliberately after reading release notes — an arbitrary-
#     code executor must not silently self-update from upstream.
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

  # Pinned to release v2026.6.5 (2026-06-06). Controlled updates ONLY — bump this
  # digest deliberately. Do NOT switch to :latest / :main (rebuilt daily).
  image = "docker.io/nousresearch/hermes-agent@sha256:9ad3b04ec916ea2c2da22358fd43b024c788d74073210695af88bfc2e63869b4";
in {
  options.homelab.services.hermes-agent = {
    enable = lib.mkEnableOption "Hermes Agent (Nous Research) — locked-down OCI container";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes";
      description = "Persistent state (skills, memory, sessions, config.yaml). Bind-mounted to /opt/data.";
    };

    dashboard = {
      enable = lib.mkEnableOption "the Hermes web dashboard. OFF by default (zero inbound). Hermes refuses an unauthenticated non-loopback bind, so enabling also needs a DashboardAuthProvider or --insecure; published host-loopback only, reached via `ssh -L`";
    };

    dashboardPort = lib.mkOption {
      type = lib.types.port;
      default = 9119;
      description = "Host loopback port for the dashboard when dashboard.enable is set. Reach via `ssh -L`, never LAN/public.";
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
    # Rootful podman backend. NOTE: hermes is deliberately NOT added to
    # homelab.podman.containers — no nightly auto-pull (see header).
    homelab.podman.enable = true;

    # Per-host secret: LLM provider API key + Telegram bot token + allowlist.
    # dotenv → injected as container env. Lives only on hermes (hosts/hermes/).
    sops.secrets."hermes-env" = {
      sopsFile = config.homelab.secrets.sopsFile "hermes.env";
      format = "dotenv";
      mode = "0400";
    };

    virtualisation.oci-containers.containers.hermes = {
      inherit image;
      autoStart = true;
      pull = "missing"; # digest-pinned; never silently fetches a different image
      cmd = ["gateway" "run"];
      environment =
        {
          TZ = "Australia/Perth";
        }
        // lib.optionalAttrs cfg.dashboard.enable {
          HERMES_DASHBOARD = "1";
        };
      environmentFiles = [config.sops.secrets."hermes-env".path];
      volumes = ["${cfg.dataDir}:/opt/data"];
      # No published ports unless the dashboard is enabled; then loopback-only
      # (reach via `ssh -L`), never LAN/tailnet. Outbound (Telegram + LLM) is
      # unaffected either way.
      ports = lib.optionals cfg.dashboard.enable ["127.0.0.1:${toString cfg.dashboardPort}:9119"];
      extraOptions = [
        "--memory=${cfg.memory}"
        "--cpus=${cfg.cpus}"
        # NO docker socket, NO --privileged — the VM is the trust boundary.
      ];
    };

    # Rotate the secret → restart the container to pick up new creds.
    systemd.services.podman-hermes.restartTriggers = [
      config.sops.secrets."hermes-env".path
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 root root - -"
    ];
  };
}
