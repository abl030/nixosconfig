# NixOS OCI containers: a reliability-first guide

**Podman is the right backend for your NixOS 25.05 homelab, but it demands specific configuration to avoid well-documented DNS and networking pitfalls.** The `virtualisation.oci-containers` module generates thin systemd wrappers around `podman run` / `docker run` commands — reliable once you understand exactly what it does and doesn't do. The module's biggest gap is image lifecycle management: it defaults to `--pull missing`, meaning `:latest` tags go stale silently. The practical fix is a combination of `podman.pull = "always"`, a weekly pull-and-restart timer, and `autoPrune`. Below is the complete picture, drawn from nixpkgs source code, NixOS Discourse threads, GitHub issues, and community configurations.

---

## Podman wins on NixOS 25.05, but set DNS explicitly

The backend defaults to **Podman for any system with `stateVersion >= "22.05"`**, which includes NixOS 25.05. The source code on current master reads:

```nix
default = if versionAtLeast config.system.stateVersion "22.05" then "podman" else "docker";
```

Podman's daemonless architecture aligns well with NixOS's declarative model. There is no persistent `dockerd` process consuming memory, no socket granting root-equivalent access to `docker` group members, and Podman integrates with systemd via `Type = "notify"` and `sd-notify`, giving systemd genuine health awareness of container state. Docker uses `Type = "simple"`, which only knows whether the process is alive.

**The case against Docker** is straightforward: the Docker daemon runs as root, members of the `docker` group effectively have root access, and you gain nothing in return since `oci-containers` generates identical systemd services for both backends. Docker's one advantage — slightly fewer networking surprises — doesn't outweigh the architectural mismatch.

**Podman DNS is the primary gotcha.** Multiple GitHub issues (#226365, #272480, #282361) document broken container-to-container DNS resolution across NixOS releases. The fix is explicit and mandatory:

```nix
virtualisation.podman = {
  enable = true;
  defaultNetwork.settings.dns_enabled = true;
};
networking.firewall.interfaces.podman0.allowedUDPPorts = [ 53 ];
```

Without `dns_enabled = true`, containers on the same Podman network cannot resolve each other by name. Without the firewall rule, DNS queries from containers get silently dropped by NixOS's default-deny firewall. These two lines should be in every NixOS Podman configuration.

**Rootless Podman now works** via the `podman.user` option added in PR #368565. For a homelab prioritizing reliability, however, rootful Podman (the default) through system-level systemd services is simpler and better-tested. Rootless introduces complications with port binding below 1024, storage driver limitations on ZFS, and additional linger configuration. Run containers as root at the systemd level and use the `user = "1000:1000"` option within the container definition to drop privileges inside the container — this is the pattern recommended by experienced NixOS users on Discourse.

---

## How the module creates systemd services

The `oci-containers` module generates one systemd service per container, named **`${backend}-${name}.service`** (e.g., `podman-jdownloader.service`). Understanding the generated service is essential for debugging.

**The generated unit structure** for a Podman container looks like this:

```ini
[Unit]
After=network-online.target podman-other-container.service
Wants=network-online.target
Requires=podman-other-container.service

[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Type=notify
NotifyAccess=all
ExecStartPre=/nix/store/.../pre-start
ExecStart=/nix/store/.../start  # calls: exec podman run --name=X --pull missing ...
ExecStop=podman stop --ignore --cidfile=...
TimeoutStartSec=0
TimeoutStopSec=120
Restart=on-failure
```

The **pre-start script** removes any leftover container with the same name (`podman rm -f`), handles registry login if configured, and loads images from the Nix store if `imageFile` or `imageStream` is set. The **start script** calls `exec podman run` with `--replace`, `-d`, and `--rm` flags, plus all configured ports, volumes, environment variables, and extra options.

Key defaults to know: **`Restart = "on-failure"`** (not `always` — changed from `always` in older nixpkgs versions), **`TimeoutStopSec = 120`** (containers get 2 minutes to stop gracefully), and **`autoStart = true`** (adds `wantedBy = multi-user.target`). If you need containers to always restart regardless of exit code, override the restart policy:

```nix
systemd.services.podman-jdownloader.serviceConfig.Restart = lib.mkForce "always";
```

**The `dependsOn` option only accepts other container names**, not arbitrary systemd units. For NFS mount dependencies, override the systemd service directly:

```nix
systemd.services.podman-kopia = {
  after = [ "mnt-backup.mount" ];
  requires = [ "mnt-backup.mount" ];
};
```

Alternatively, use systemd's `RequiresMountsFor` directive, which automatically creates dependencies for all mount units covering a given path.

**On `nixos-rebuild switch`**, NixOS compares old and new systemd unit files. **Only containers whose configuration actually changed get restarted.** If you change ports, volumes, environment variables, or the image string, the generated start script changes, triggering a stop-then-start cycle. If nothing changed — including when `:latest` still points to the same string — the service is untouched. Container logs go to journald by default for both backends, accessible via `journalctl -u podman-containername.service`.

---

## Solving the image update lifecycle

This is the hardest problem with `oci-containers`, and the community has converged on a layered approach rather than a single solution.

**The core issue**: the module defaults to `--pull missing`, meaning an image is only pulled if it doesn't exist locally. A `nixos-rebuild` that doesn't change the container's Nix configuration won't restart the service or re-pull the image. GitHub issue #172765 has tracked this since May 2022.

**Layer 1: Set `pull = "newer"`.** This option checks the registry digest and only pulls if a newer image exists:

```nix
virtualisation.oci-containers.containers.jdownloader = {
  image = "jlesage/jdownloader-2:latest";
  pull = "newer";
  # ... other config
};
```

> **Correction (2026-02-26):** Many community examples show `podman.pull = "always"` but the actual nixpkgs option path is simply `pull` — it's a top-level container option, not nested under a `podman` attrset. The option accepts `"always"`, `"missing"`, `"never"`, or `"newer"` and defaults to `"missing"`. Despite some blog posts claiming it's Podman-specific, the option exists for both backends in current nixpkgs.

> **Update (2026-02-26):** Prefer `"newer"` over `"always"`. The critical difference: when the registry is unreachable or rate-limited, `"newer"` **silently falls back to the local image** (`"Pull errors are suppressed if a local image was found"` — [podman-pull docs](https://docs.podman.io/en/latest/markdown/podman-pull.1.html)). With `"always"`, a registry failure means the container **cannot start at all**, even if the image is cached locally. This caused a real outage: Docker Hub rate limits triggered a restart loop where youtarr kept failing to pull on every retry, burning through rate limits even faster. `"newer"` would have started the local image immediately.

**Layer 2: A weekly pull-and-restart timer.** Since `pull = "newer"` only triggers on service start, you need something to periodically restart services. The Nixcademy blog by Jacek Galowicz documents a proven pattern used on production systems for over a year:

```nix
systemd.services.update-containers = {
  serviceConfig.Type = "oneshot";
  script = ''
    images=$(${pkgs.podman}/bin/podman ps -a --format="{{.Image}}" | sort -u)
    for image in $images; do
      ${pkgs.podman}/bin/podman pull "$image"
    done
    ${pkgs.systemd}/bin/systemctl restart podman-jdownloader.service
    ${pkgs.systemd}/bin/systemctl restart podman-kopia.service
    ${pkgs.systemd}/bin/systemctl restart podman-netbootxyz.service
  '';
};
systemd.timers.update-containers = {
  wantedBy = [ "timers.target" ];
  timerConfig.OnCalendar = "Mon 02:00";
  timerConfig.Persistent = true;
};
```

Explicitly listing services to restart is safer than restarting every `podman-*` service blindly, and makes the update schedule visible in your Nix config.

**Layer 3 (optional, for the Nix-purist path): Pin image tags with Renovate Bot.** Multiple NixOS homelab operators use Renovate to scan `.nix` files for container image references and automatically create PRs when new versions appear. A regex manager config matches the `image = "name:tag"` pattern in Nix files. This is the most reproducible approach — every image version is tracked in Git — but requires a CI/CD pipeline and is overkill for a homelab that just wants `:latest` to stay current.

**Watchtower was archived December 17, 2025.** The most viable successor is `nickfedor/watchtower`, a maintained fork that's a drop-in replacement. However, for NixOS users already running Podman, the timer-based approach above is simpler and doesn't require running yet another container. What's Up Docker (WUD) is a good choice if you want a web UI to monitor pending updates before applying them. Diun is notification-only and pairs well with manual updates.

**`podman auto-update` can work** but requires adding the label manually since `oci-containers` doesn't set it by default:

```nix
extraOptions = [ "--label=io.containers.autoupdate=registry" ];
```

You'd also need to enable the `podman-auto-update.timer` systemd unit. The community tool **quadlet-nix** provides a more integrated path to Podman Quadlet (systemd-native container management) with first-class `auto-update` support, but it's a third-party module and a bigger departure from `oci-containers`.

---

## Pruning configuration and the one flag you must never set

Both `virtualisation.docker.autoPrune` and `virtualisation.podman.autoPrune` are structurally identical: they create a systemd timer that calls `system prune -f` with configurable flags and schedule. The recommended configuration:

```nix
virtualisation.podman.autoPrune = {
  enable = true;
  dates = "weekly";
  flags = [ "--all" ];
};
```

**Without `--all`**, only dangling (untagged) images are removed. **With `--all`**, any image not actively used by a running container gets pruned. This is safe when combined with `pull = "newer"` because services re-pull on next start. The risk scenario: if pruning runs during a brief window when a container has crashed and hasn't restarted yet, its image gets removed, and the restart then requires a network pull. On a homelab with reliable internet, this is acceptable.

**Never add `--volumes` to autoPrune flags.** This removes unused named volumes and can destroy persistent data. Bind mounts are immune to volume pruning (they're just filesystem paths), which is one more reason to prefer bind mounts for persistent data.

A conservative alternative uses a time filter to only prune images older than 24 hours: `flags = [ "--all" "--filter" "until=24h" ]`. This provides a safety buffer during transient outages.

---

## Storage: bind mounts to explicit paths, not named volumes

The NixOS community overwhelmingly favors **bind mounts over named Docker/Podman volumes** for persistent container data. Bind mounts are explicit in your Nix config, trivial to back up, and work cleanly with impermanence setups. Named volumes are opaque — stored deep inside `/var/lib/containers/storage` — and harder to manage declaratively.

The most common directory patterns in community configs:

```nix
volumes = [
  "/var/lib/jdownloader:/config"           # FHS-conventional
  "/mnt/storage/kopia:/data"               # NFS/external storage
  "/etc/localtime:/etc/localtime:ro"       # timezone sync (common pattern)
];
```

For **impermanence setups**, persist the container runtime's entire data directory:

```nix
environment.persistence."/persist".directories = [ "/var/lib/containers" ];
```

**Filesystem gotchas**: On **btrfs**, Podman's overlay storage driver can create excessive subvolumes. Set the storage driver explicitly via `virtualisation.containers.storage.settings.storage.driver = "btrfs"` or accept overlay's behavior. On **ZFS**, rootless Podman cannot use the ZFS storage driver; the underlying dataset needs `acltype=posixacl` for overlay to work correctly. For **NFS/CIFS mount sources**, the systemd dependency management described above (`after` + `requires` on mount units) is essential — without it, containers race against mounts on boot and fail intermittently. The `compose2nix` tool has a `-check_systemd_mounts` flag that automates this dependency detection.

---

## The community prefers native modules first, containers as fallback

The dominant NixOS homelab philosophy is clear: **use native NixOS modules when they exist, containerize only what you must.** Native modules integrate with NixOS's declarative config, receive security updates through nixpkgs, and don't require a container runtime. Blog posts and GitHub configs consistently show services like Nginx, Caddy, Grafana, Prometheus, PostgreSQL, WireGuard, Sonarr, Radarr, Jellyfin, and Plex running natively.

Containers fill the gaps: Home Assistant (complex ecosystem, USB passthrough), Immich (requires PostgreSQL with pgvecto.rs extension), and niche tools like JDownloader2 or Netboot.xyz where upstream only publishes Docker images. As one NixOS user on Discourse put it: "I don't think there is much benefit going with pure Nix module here... other than fulfilling the purism many Nix users seem to have."

Notable community resources for reference configurations include **rwiankowski/homeserver-nixos** (20+ services, enterprise-grade), **badele/nix-homelab** (multi-host with Hetzner and Raspberry Pi), and the **nixarr** project (dedicated NixOS module for media server stacks). The **compose2nix** tool is the most popular bridge for users migrating from Docker Compose — it generates complete `oci-containers` NixOS configs from `docker-compose.yaml` files, handling networks, volumes, and dependencies.

There is no networking abstraction in `oci-containers` for creating Podman networks. If your containers need to communicate (e.g., an app container talking to its database), create networks via a systemd oneshot:

```nix
systemd.services.create-podman-network = {
  serviceConfig.Type = "oneshot";
  wantedBy = [ "podman-myapp.service" ];
  script = ''
    ${pkgs.podman}/bin/podman network exists mynet || \
    ${pkgs.podman}/bin/podman network create mynet
  '';
};
```

Then attach containers with `extraOptions = [ "--network=mynet" ]`.

---

## Conclusion: the complete reliability-first configuration

For a NixOS 25.05 homelab running ~14 native services alongside JDownloader2, Kopia, and Netboot.xyz in containers, here is the synthesized recommendation:

```nix
# Enable Podman with DNS fix
virtualisation.podman = {
  enable = true;
  defaultNetwork.settings.dns_enabled = true;
  autoPrune = {
    enable = true;
    dates = "weekly";
    flags = [ "--all" ];
  };
};
networking.firewall.interfaces.podman0.allowedUDPPorts = [ 53 ];

# Container definitions
virtualisation.oci-containers = {
  backend = "podman";
  containers.jdownloader = {
    image = "jlesage/jdownloader-2:latest";
    pull = "newer";
    volumes = [ "/var/lib/jdownloader:/config" ];
    ports = [ "5800:5800" ];
  };
  # ... kopia, netbootxyz similarly
};

# NFS mount dependency (if applicable)
systemd.services.podman-kopia = {
  after = [ "mnt-backup.mount" ];
  requires = [ "mnt-backup.mount" ];
};
```

Combined with the weekly pull-and-restart timer, this setup ensures containers always run, always update, and never need manual intervention. The three critical lines most people miss are `dns_enabled = true`, the firewall rule for UDP 53, and `pull = "newer"`. Without them, you'll spend hours debugging silent failures. With them, NixOS manages containers as reliably as its native services.
