# qbt — the isolated qBittorrent microVM (Forgejo #1).
# Architecture + the virtiofs-over-NFS storage gotcha chain + cage details:
#   docs/wiki/services/servarr-and-qbt-cage.md
#
# This is the ONE genuinely-hostile-input box: internet-facing libtorrent with an
# inbound VPN port. So it gets VM-grade isolation via microvm.nix / cloud-
# hypervisor, nested inside servarr (tower has nested virt = Y; servarr's vCPU must
# be host-passthrough — set in the tower libvirt def at install).
#
# Containment model — the FIREWALL is the boundary, not the guest:
#   NET  — its own LAN IP on VLAN 20 (Torrent_DMZ, 192.168.20.2). pfSense policy-
#          routes it out AirVPN only + kill-switch, default-denies it to the whole
#          fleet/LAN/other VLANs, allows exactly ONE inbound (servarr → qbt:8080),
#          and forwards the AirVPN port → qbt:45726. The guest just needs a correct
#          address; all deny / VPN / kill-switch logic lives at pfSense.
#   DISK — three windows ONLY: RO /nix/store (virtiofs), a small writable state
#          volume, and /downloads = a virtiofs view of a SCRATCH SUBDIR of the
#          library fs. It never sees the library or the rest of /data. servarr
#          (trusted) hardlinks completed files from the scratch into the library.
#
# INSTALL-TIME TODO (marked inline): servarr's VLAN-20 uplink interface name
# (its 2nd vNIC, bridged to tower br0.20).
{
  lib,
  pkgs,
  inputs,
  ...
}: let
  # servarr's 2nd vNIC — attached on tower to br0.20 (VLAN 20). Confirmed at install
  # (2026-06-22): the LAN NIC is enp1s0, the VLAN-20 NIC is enp2s0 (predictable PCI
  # naming from the libvirt q35 topology; stable across NixOS versions).
  dmzUplink = "enp2s0";

  # virtiofsd over the Unraid NFS-backed scratch: that backend supports NEITHER POSIX
  # ACLs NOR user xattrs (both return EOPNOTSUPP / "Operation not supported"), but
  # microvm.nix HARDCODES `--posix-acl --xattr` on virtiofsd. So libtorrent's file ops
  # in the qbt guest failed with "Operation not supported" and downloads never wrote.
  # Wrap virtiofsd to strip those two flags (harmless for the RO /nix/store share too).
  # This keeps the cage intact — no NFS pinhole, no architecture change. See Forgejo #1.
  virtiofsdNoXattr = pkgs.writeShellScriptBin "virtiofsd" ''
    args=()
    for a in "$@"; do
      case "$a" in
        --posix-acl | --xattr) ;;
        *) args+=("$a") ;;
      esac
    done
    exec ${lib.getExe pkgs.virtiofsd} "''${args[@]}"
  '';

  # Public tracker list, baked from the `trackerslist` flake input (auto-refreshed by
  # the nightly rolling-flake-update — a new list rolls out on the next qbt restart).
  # ngosang/trackerslist trackers_best.txt is ~20 curated all-UDP trackers — the sweet
  # spot for peer reach. More is net-negative (dead/duplicate trackers + announce/DNS/TLS
  # overhead; DHT/PEX cover the rest). Joined into qBittorrent's AdditionalTrackers value
  # (one URL per line — QSettings serialises the newlines as `\n` in qBittorrent.conf).
  bestTrackers =
    lib.filter (l: lib.strings.hasInfix "://" l)
    (lib.splitString "\n" (builtins.readFile "${inputs.trackerslist}/trackers_best.txt"));
  additionalTrackers = lib.concatStringsSep "\\n" bestTrackers;

  # ── qBittorrent.conf: MERGE the Nix-managed keys; do NOT clobber the whole file ──
  # The upstream services.qbittorrent module installs a freshly-generated qBittorrent.conf
  # (containing ONLY the serverConfig keys) over the real one on EVERY service start. That
  # reset every WebUI-set preference to qBittorrent's defaults on each boot/restart — the
  # "settings don't persist after a reboot" bug. (Torrent state survived because it lives in
  # a different dir, BT_backup/, that the install never touched.)
  #
  # So we DON'T set serverConfig. Instead managedConf below is the single source of truth for
  # the keys Nix owns, and the merge pre-start (qbtMergeConfig) splices just those keys into
  # the guest's persisted conf — leaving every other (user/WebUI-set) key intact. Net:
  #   • user/WebUI settings persist across reboots, and
  #   • the managed keys (WebUI bind/whitelist, save path, nightly tracker list) are still
  #     re-applied on every start, so the tracker refresh keeps working (restartTriggers on
  #     managedConf re-runs the merge whenever a nightly flake bump changes the list).
  #
  # Managed keys (was serverConfig — rationale preserved here):
  #   WebUI\Address=*                       bind all guest ifaces; reached via pfSense from
  #                                         servarr (and qbt.ablz.au through servarr's nginx).
  #   WebUI\AuthSubnetWhitelist[Enabled]    no-creds path for the LAN subnet qbt sees (pfSense
  #                                         ROUTES LAN→VLAN20, no NAT → real .101); pfSense
  #                                         permits ONLY servarr→8080, so humans are LAN-only.
  #   Session\DefaultSavePath=/downloads/   qbt writes ONLY into the virtiofs scratch; *arr
  #                                         hardlink completed files out of there. Never /data.
  #   Session\Add[itional]Trackers          auto-append the public list to NEW torrents.
  # Format = qBittorrent's own INI: backslash-nested keys, lowercase bools, AdditionalTrackers
  # one line with `\n`-escaped URLs (QSettings unescapes them back to newlines on read).
  managedConf = pkgs.writeText "qBittorrent-managed.conf" ''
    [BitTorrent]
    Session\AddTrackersEnabled=true
    Session\AdditionalTrackers=${additionalTrackers}
    Session\DefaultSavePath=/downloads/

    [Preferences]
    WebUI\Address=*
    WebUI\AuthSubnetWhitelistEnabled=true
    WebUI\AuthSubnetWhitelist=192.168.1.0/24
  '';

  # Pre-start, run before qbittorrent-nox as the service user while the conf is quiescent:
  #   • fresh state volume (no conf) → seed exactly the managed keys;
  #   • existing conf → crudini-merge the managed keys in, preserving every other key, then
  #     normalise crudini's `k = v` back to qBittorrent's own `k=v`.
  # Merge failure is deliberately NON-fatal: fall through and start with the existing conf
  # (managed keys persist from the previous merge) rather than brick a live torrent box.
  qbtMergeConfig = pkgs.writeShellScript "qbt-merge-config" ''
    set -u
    conf="/var/lib/qBittorrent/qBittorrent/config/qBittorrent.conf"
    if [ ! -e "$conf" ]; then
      ${pkgs.coreutils}/bin/install -Dm600 ${managedConf} "$conf"
      exit 0
    fi
    if ${pkgs.crudini}/bin/crudini --merge --inplace "$conf" < ${managedConf}; then
      ${pkgs.gnused}/bin/sed -i -E 's/^([^=]*[^= ]) = /\1=/' "$conf"
      ${pkgs.coreutils}/bin/chmod 600 "$conf"
    else
      echo "qbt-merge-config: crudini merge failed; starting with existing conf" >&2
    fi
  '';

  # ── B2 (host): qbt guest-health watchdog — the 2026-06-29 tower-reboot blind spot ──
  # The host NFS watchdog (homelab.nfsWatchdog.qbt, below) only stats the SERVER side of
  # the scratch on servarr — it stays green even when the GUEST's /downloads virtiofs
  # view is wedged. That exact blind spot stranded qbt for ~1h after a tower reboot:
  # servarr's NFS mount was healthy, but virtiofsd had grabbed a tower-shfs handle before
  # the share settled, the handle went ESTALE, the guest's /downloads mount hung,
  # qBittorrent ran against a dead save path, and the host watchdog never tripped (path
  # fine + VM "active"). Only a manual `systemctl restart microvm@qbt` (fresh virtiofsd)
  # fixed it. This probes qbt the one way only servarr can (pfSense permits servarr→
  # qbt:8080, and servarr's .4 is in the WebUI AuthSubnetWhitelist so no creds) and
  # re-rolls the VM when the guest is genuinely unhealthy. See the cage wiki for the RCA.
  qbtHealthCheck = pkgs.writeShellScript "qbt-health-check" ''
    set -u
    api="http://192.168.20.2:8080/api/v2"
    # Healthy /downloads is the tower array (~1 TB free). A stale/unmounted share falls
    # back to the 768 MiB guest's tmpfs root (sub-GiB). 5 GiB is a wide moat: far above
    # any tmpfs fallback, far below the array's real free space (no false trips).
    floor=5368709120

    sc=${pkgs.systemd}/bin/systemctl
    curl="${pkgs.curl}/bin/curl -fsS -m 8"

    # Only act on a SETTLED VM: skip if microvm@qbt isn't active, or (re)started within
    # the last 3 min — qbt's WebUI needs ~60-70s to come up, so don't fight a normal
    # boot/restart (this also rate-limits our own re-rolls to one per timer window).
    "$sc" is-active --quiet microvm@qbt.service || exit 0
    mono=$("$sc" show microvm@qbt.service -p ActiveEnterTimestampMonotonic --value)
    up=$(${pkgs.coreutils}/bin/cut -d. -f1 /proc/uptime)
    if [ -n "$mono" ] && [ "$mono" -gt 0 ]; then
      [ $(( up - mono / 1000000 )) -lt 180 ] && exit 0
    fi

    restart() {
      echo "qbt-health: $1 — restarting microvm@qbt" >&2
      "$sc" reset-failed microvm@qbt.service 2>/dev/null || true
      "$sc" restart microvm@qbt.service
      exit 0
    }

    # Liveness — ride out a brief blip (a few retries) before declaring qbt down.
    ver=""
    for _ in 1 2 3 4 5 6; do
      ver=$($curl "$api/app/version" 2>/dev/null) && break
      ${pkgs.coreutils}/bin/sleep 5
    done
    [ -n "$ver" ] || restart "WebUI unreachable (qbt down — e.g. qBittorrent refused a failed /downloads)"

    # Save-path sanity — free space must look like the array, not the tmpfs root.
    free=$($curl "$api/sync/maindata?rid=0" 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.server_state.free_space_on_disk // empty' 2>/dev/null)
    case "$free" in
      "" | *[!0-9]*) exit 0 ;; # unreadable → don't act on noise
    esac
    [ "$free" -lt "$floor" ] && restart "free_space_on_disk=$free < $floor (/downloads stale or unmounted)"
  '';
in {
  imports = [inputs.microvm.nixosModules.host];

  # Host L2 conduit: a bridge joining servarr's VLAN-20 uplink + the qbt tap.
  # servarr itself takes NO IP here — it only transports qbt's frames to tower
  # br0.20 → eth0.20 → switch (VLAN 20 tagged) → pfSense. servarr stays on the
  # main LAN (.4) via its primary NIC; this bridge is a pure cage conduit.
  systemd.network.enable = true;
  # NetworkManager owns servarr's real connectivity (the LAN NIC / .4) and has its
  # own NetworkManager-wait-online. networkd here manages ONLY the DMZ cage, which is
  # intentionally IP-less and never reaches "online" — so systemd-networkd-wait-online
  # would always time out (→ host `degraded`). Per its own docs, disable it when a
  # different service manages the system's connection. network-online.target is still
  # satisfied via NetworkManager-wait-online.
  systemd.network.wait-online.enable = false;
  systemd.network.netdevs."br-dmz".netdevConfig = {
    Name = "br-dmz";
    Kind = "bridge";
  };
  systemd.network.networks."40-br-dmz" = {
    matchConfig.Name = "br-dmz";
    networkConfig.ConfigureWithoutCarrier = true;
    linkConfig.RequiredForOnline = false;
  };
  systemd.network.networks."41-dmz-uplink" = {
    matchConfig.Name = dmzUplink; # the VLAN-20 vNIC — bridge member, no IP
    networkConfig.Bridge = "br-dmz";
    linkConfig.RequiredForOnline = false;
  };
  systemd.network.networks."42-dmz-tap" = {
    matchConfig.Name = "vm-qbt"; # the tap microvm.nix creates from the id below
    networkConfig.Bridge = "br-dmz";
    linkConfig.RequiredForOnline = false;
  };

  # The base profile uses NetworkManager, which owns the LAN NIC (DHCP → servarr's
  # .4). Keep NM OFF the DMZ interfaces — systemd-networkd owns br-dmz + the VLAN-20
  # uplink + the qbt tap. Without this NM would also DHCP the VLAN-20 vNIC (pulling a
  # 192.168.20.x onto servarr, which must stay a pure L2 conduit) and fight the bridge.
  networking.networkmanager.unmanaged = [
    "interface-name:${dmzUplink}"
    "interface-name:br-dmz"
    "interface-name:vm-qbt"
  ];

  # ── A (host): gate the virtiofs daemon on the NFS scratch being MOUNTED ──────────
  # microvm-virtiofsd@qbt is the process that opens the handle into the scratch; stock
  # it only orders after local-fs.target, NOT the (remote-fs / _netdev) tower NFS mount.
  # So at boot it could start before /media/data is mounted (2026-06-29 it won the race
  # by only 3s — pure luck) and, worse, grab a tower-shfs handle while the share is still
  # settling → the ESTALE wedge that stranded qbt. RequiresMountsFor pulls in + orders
  # after media-data.mount; microvm@qbt already Requires+After virtiofsd, so the whole VM
  # now waits for a real, settled mount. Merges into microvm.nix's per-instance drop-in
  # for this unit (it sets overrideStrategy=asDropin), so this is just a [Unit] add-on.
  systemd.services."microvm-virtiofsd@qbt".unitConfig.RequiresMountsFor = "/media/data/Media/Temp";

  # ── B2 (host): qbt guest-health watchdog (script + full rationale in the let above) ──
  systemd.services.qbt-health = {
    description = "qbt guest-health watchdog (WebUI liveness + save-path sanity)";
    serviceConfig = {
      Type = "oneshot";
      NoNewPrivileges = true; # curl + systemctl only; no setuid exec (#232)
      ExecStart = qbtHealthCheck;
    };
  };
  systemd.timers.qbt-health = {
    description = "qbt guest-health watchdog timer";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "4min";
      OnUnitActiveSec = "5min";
    };
  };

  # Alert when the guest-health watchdog re-rolls the VM (mirrors the nfsWatchdog alert).
  homelab.monitoring.errorPatterns = [
    {
      name = "qbt guest-health watchdog re-rolled qbt";
      unit = "qbt-health.service";
      pattern = "(?i)qbt-health:.*restarting microvm@qbt";
      severity = "warning";
      summary = "qbt's guest /downloads view was stale/unreachable; the microVM was restarted";
      threshold = 0;
      description = ''
        servarr's qbt-health watchdog probed the qBittorrent WebUI and found qbt either
        down or pointing at a tmpfs-sized save path (a stale/unmounted /downloads
        virtiofs share), and restarted microvm@qbt to re-roll virtiofsd. A single trip
        after a tower reboot is expected self-healing. Repeated trips = the virtiofs-
        over-NFS scratch is genuinely flaky; see docs/wiki/services/servarr-and-qbt-cage.md.
      '';
    }
  ];

  microvm.vms.qbt.config = {
    imports = [inputs.microvm.nixosModules.microvm];

    networking.hostName = "qbt";
    system.stateVersion = "25.05";

    microvm = {
      hypervisor = "cloud-hypervisor";
      vcpu = 2;
      mem = 768;
      vsock.cid = 20; # systemd-notify over vsock → servarr knows when qbt is up
      # NFS-backed /downloads share rejects ACLs/xattrs → strip --posix-acl/--xattr.
      virtiofsd.package = virtiofsdNoXattr;
      shares = [
        {
          # RO /nix/store from the host — no per-VM store duplication (tiny RAM).
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }
        {
          # The ONLY data window: a scratch subdir of the library fs. NEVER the
          # library, NEVER the rest of /data. servarr hardlinks OUT of here.
          source = "/media/data/Media/Temp";
          mountPoint = "/downloads";
          tag = "downloads";
          proto = "virtiofs";
        }
      ];
      volumes = [
        {
          # Persistent qbt state (config, session, .fastresume). The mountPoint MUST
          # match services.qbittorrent.profileDir — nixpkgs default `/var/lib/qBittorrent`
          # (capital Q + B). A lowercase `/var/lib/qbittorrent` silently mounts the volume
          # on a path qBittorrent never writes, so its state lands on the EPHEMERAL microVM
          # root and is wiped on every restart/reboot (the lost-torrents bug; fixed
          # 2026-06-23 — the volume had been mounted one case off and sat empty).
          mountPoint = "/var/lib/qBittorrent";
          image = "qbt-state.img"; # lands under /var/lib/microvms/qbt/ on servarr
          size = 1024; # MiB
        }
      ];
      interfaces = [
        {
          type = "tap";
          id = "vm-qbt";
          mac = "02:00:00:00:20:02"; # locally-administered; corresponds to .20.2
        }
      ];
    };

    # ── B1 (guest): fail FAST, not silently, if /downloads can't mount ───────────────
    # Bound the virtiofs mount so a wedged/stale share FAILS in 60s instead of hanging
    # forever — on 2026-06-29 it hung indefinitely and qBittorrent started anyway against
    # an empty save path. microvm.nix sets this share's options to a plain list, so the
    # timeout concatenates onto it. (qBittorrent then refuses to start without it — see
    # its RequiresMountsFor below — so a failed mount surfaces as "qbt down", which the
    # host qbt-health watchdog catches and re-rolls the VM with a fresh virtiofsd.)
    fileSystems."/downloads".options = ["x-systemd.mount-timeout=60"];

    # VLAN-20 address only. Egress restriction / kill-switch / default-deny all
    # live at pfSense — the guest just needs IP + gateway + DNS-via-pfSense.
    systemd.network.enable = true;
    systemd.network.networks."10-eth" = {
      matchConfig.Type = "ether";
      address = ["192.168.20.2/24"];
      routes = [{Gateway = "192.168.20.1";}];
      networkConfig.DNS = "192.168.20.1";
    };

    # qBittorrent headless. WebUI 8080 (only servarr may reach it, per the pfSense
    # inbound exception). Listen 45726 = the reused AirVPN forward. Categories
    # radarr / tv-sonarr / sonarr / prowlarr (= the old deluge labels) are created
    # at migration so the *arr download-client config maps 1:1.
    services.qbittorrent = {
      enable = true;
      # Run as gid 100 (`users`) = the group that owns the NFS scratch dir
      # (/media/data/Media/Temp is 99:100, mode 2775/setgid). virtiofs passes the
      # guest's egid through, so this lets qbt actually WRITE downloads (else EACCES).
      group = "users";
      webuiPort = 8080;
      torrentingPort = 45726;
      # Open 8080 (WebUI) + 45726 (torrent) on the GUEST firewall. pfSense is still the
      # real boundary (default-deny egress → AirVPN only; single inbound servarr→8080; the
      # AirVPN forward → 45726). The guest firewall just must not DROP those allowed flows —
      # with openFirewall=false it silently blocked the WebUI (HTTP 000) and inbound peers.
      openFirewall = true;
      # serverConfig is intentionally NOT set: the module would install it over
      # qBittorrent.conf on every start, wiping all WebUI-set prefs. The managed keys are
      # MERGED in via the ExecStartPre override below instead — see managedConf in the let.
    };

    systemd.services.qbittorrent = {
      # Re-apply ONLY the managed keys via the merge pre-start (managedConf / qbtMergeConfig
      # in the let above) instead of the module's whole-file clobber, so WebUI settings
      # persist across reboots. mkForce wins over any module-provided ExecStartPre.
      # restartTriggers re-runs the merge (→ fresh tracker list) whenever managedConf changes.
      restartTriggers = [managedConf];
      serviceConfig.ExecStartPre = lib.mkForce "${qbtMergeConfig}";

      # B1: hard-require /downloads (Requires + After downloads.mount). NEVER start
      # qBittorrent against an unmounted save path — it would write into the EPHEMERAL
      # guest root and lose both the in-flight data and torrent state on the next
      # restart. If the mount fails its 60s timeout above, qBittorrent stays down → WebUI
      # down → the host qbt-health watchdog re-rolls the VM (fresh virtiofsd) and recovers.
      unitConfig.RequiresMountsFor = "/downloads";

      # Downloads land on the NFS scratch, where the backend squashes qbt's uid to 99
      # (nobody); qbt re-opens its OWN files for writing via gid 100 (group), so they
      # must be GROUP-WRITABLE. Default umask 022 → 0664... → 0644 (group read-only) →
      # EACCES on file_open. umask 002 → 0664 → qbt writes; *arr read/hardlink via group.
      serviceConfig.UMask = "0002";
    };

    # No fleet trust, no tailscale, nothing else. This box is disposable.
    networking.firewall.enable = lib.mkDefault true;
    networking.firewall.allowedUDPPorts = [45726]; # uTP/DHT inbound (TCP opened by openFirewall)
  };
}
