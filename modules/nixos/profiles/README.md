# NixOS Profiles

Base profiles automatically imported for all NixOS hosts.

## Design Decisions

### Coredump storage cap (100MB)

Rootless Podman containers run as the host user's UID, so container
segfaults are captured by the host's `systemd-coredump` handler. A
crash-looping container (e.g. Ombi generating 30,000+ coredumps, 4.1GB)
can fill disk quickly. `MaxUse=100M` keeps recent dumps for debugging
while bounding worst-case disk usage. This is fleet-wide in `base.nix`.
