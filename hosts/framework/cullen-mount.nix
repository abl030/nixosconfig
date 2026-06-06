# On-demand SSHFS access to the Cullen office Z: drive (CW-DC01 file server).
#
# The drive is mounted read-only into the `wsl` host (Windows Z: over 9p/drvfs).
# framework reaches wsl only through the Windows host's :22 Tailscale
# port-forward (`ssh wsl` -> nixos@laptop-btibh4ie), so SSHFS over that existing
# SSH path is the only transport that works without extra Windows-side forwards.
#
# Deliberately NOT a systemd/automount fileSystems entry: framework is a roaming
# laptop with a documented history of dead-tailnet mounts pinning the kernel on
# suspend (see the soft-mount + circuit-breaker block in configuration.nix). This
# stays fully off until you run `cullen-mount`, runs as your user (no root, no
# extra keys), and is torn down with `cullen-umount`. Nothing is touched at boot
# or suspend.
{pkgs, ...}: let
  mountPoint = "$HOME/cullen";
  remote = "wsl:/mnt/z"; # uses the `wsl` ssh alias from hosts.nix

  cullen-mount = pkgs.writeShellApplication {
    name = "cullen-mount";
    runtimeInputs = with pkgs; [sshfs fuse3 coreutils util-linux];
    text = ''
      target="${mountPoint}"

      if mountpoint -q "$target"; then
        echo "Cullen drive already mounted at $target"
        exit 0
      fi

      # A dropped connection leaves a dead FUSE endpoint: the dir exists but any
      # stat fails with "Transport endpoint is not connected". Clear it first.
      if [ -d "$target" ] && ! ls "$target" >/dev/null 2>&1; then
        fusermount3 -u "$target" 2>/dev/null || true
      fi

      mkdir -p "$target"

      echo "Mounting ${remote} -> $target (read-only, via 'ssh wsl')..."
      sshfs "${remote}" "$target" \
        -o ro \
        -o reconnect \
        -o idmap=user \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3

      echo "Mounted. Browse $target ; unmount with: cullen-umount"
    '';
  };

  cullen-umount = pkgs.writeShellApplication {
    name = "cullen-umount";
    runtimeInputs = with pkgs; [fuse3 util-linux];
    text = ''
      target="${mountPoint}"

      if fusermount3 -u "$target" 2>/dev/null; then
        echo "Unmounted $target"
      else
        echo "Nothing mounted at $target"
      fi
    '';
  };
in {
  home.packages = [cullen-mount cullen-umount];
}
