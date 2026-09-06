{
  self,
  inputs,
  lib,
  pkgs,
  system,
}: let
  # Evaluated contract for the LAN-only bdday service. Keep this focused
  # check alongside the global source audits: it proves the generated
  # unit/vhost and the host-assignment boundary, not merely module text.
  bddayIntegrationCheck = let
    doc1 = self.nixosConfigurations.proxmox-vm.config;
    bddayPackage = inputs.bdday.packages.${system}.default;
    bddayCfg = doc1.homelab.services.bdday;
    service = doc1.systemd.services.bdday.serviceConfig;
    unit = doc1.systemd.units."bdday.service".unit;
    nginxConfig = doc1.environment.etc."nginx/nginx.conf".source;
    proxy = lib.findFirst (entry: entry.host == bddayCfg.fqdn) null doc1.homelab.localProxy.hosts;
    monitor = lib.findFirst (entry: entry.url == "https://${bddayCfg.fqdn}/healthz") null doc1.homelab.monitoring.monitors;
    errorPattern = lib.findFirst (entry: entry.unit == "bdday.service") null doc1.homelab.monitoring.errorPatterns;
    unrelatedEnabled = lib.filter (
      name: self.nixosConfigurations.${name}.config.homelab.services.bdday.enable
    ) (lib.remove "proxmox-vm" (lib.attrNames self.nixosConfigurations));
    firewallText = lib.concatStringsSep "\n" [
      doc1.networking.firewall.extraCommands
      doc1.networking.firewall.extraInputRules
    ];
    expectedExecStart = "${bddayPackage}/bin/bdday serve --listen 127.0.0.1:${toString bddayCfg.port}";
  in
    pkgs.runCommand "bdday-integration" {} ''
      set -euo pipefail

      test '${lib.boolToString bddayCfg.enable}' = true
      test '${lib.boolToString (bddayCfg.package == bddayPackage)}' = true
      test ${lib.escapeShellArg bddayCfg.fqdn} = bd.ablz.au
      test ${toString bddayCfg.port} -eq 8849
      test ${lib.escapeShellArg service.ExecStart} = ${lib.escapeShellArg expectedExecStart}
      test -x ${bddayPackage}/bin/bdday

      test '${lib.boolToString service.DynamicUser}' = true
      test '${lib.boolToString service.NoNewPrivileges}' = true
      test ${lib.escapeShellArg service.ProtectSystem} = strict
      test '${lib.boolToString service.ProtectHome}' = true
      test '${lib.boolToString service.PrivateTmp}' = true
      test '${lib.boolToString service.PrivateDevices}' = true
      test -z ${lib.escapeShellArg service.CapabilityBoundingSet}
      test -z ${lib.escapeShellArg service.AmbientCapabilities}
      test '${lib.boolToString service.RestrictNamespaces}' = true
      test '${lib.boolToString service.LockPersonality}' = true
      test ${lib.escapeShellArg service.SystemCallArchitectures} = native
      test '${lib.boolToString (service.RestrictAddressFamilies == ["AF_INET" "AF_INET6"])}' = true
      test ${lib.escapeShellArg service.IPAddressDeny} = any
      test ${lib.escapeShellArg service.IPAddressAllow} = localhost

      test '${lib.boolToString (proxy != null)}' = true
      test ${lib.escapeShellArg proxy.upstreamHost} = 127.0.0.1
      test ${toString proxy.port} -eq 8849
      test '${lib.boolToString (!proxy.tailscaleOnly)}' = true
      test '${lib.boolToString (lib.hasPrefix "192.168." doc1.homelab.localProxy.localIp)}' = true
      test ${lib.escapeShellArg doc1.services.nginx.virtualHosts.${bddayCfg.fqdn}.locations."/".proxyPass} = http://127.0.0.1:8849
      test ${lib.escapeShellArg doc1.services.nginx.virtualHosts.${bddayCfg.fqdn}.useACMEHost} = bd.ablz.au
      test '${lib.boolToString (builtins.hasAttr bddayCfg.fqdn doc1.security.acme.certs)}' = true
      ${pkgs.gnugrep}/bin/grep -F '"proxied":false' ${../../modules/nixos/services/local_proxy.nix} >/dev/null

      test '${lib.boolToString (monitor != null)}' = true
      test ${lib.escapeShellArg monitor.name} = 'Biodynamic day dashboard'
      test '${lib.boolToString (errorPattern != null)}' = true
      test ${lib.escapeShellArg errorPattern.pattern} = 'panicked at|fatal runtime error'
      test ${toString errorPattern.threshold} -eq 0

      test '${lib.boolToString (!(lib.elem bddayCfg.port doc1.networking.firewall.allowedTCPPorts))}' = true
      test '${lib.boolToString (!(lib.elem bddayCfg.port doc1.networking.firewall.allowedUDPPorts))}' = true
      test '${lib.boolToString (!(lib.hasInfix (toString bddayCfg.port) firewallText))}' = true
      test -z ${lib.escapeShellArg (lib.concatStringsSep " " unrelatedEnabled)}

      ${pkgs.gnugrep}/bin/grep -F "ExecStart=${expectedExecStart}" ${unit}/bdday.service >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'DynamicUser=true' ${unit}/bdday.service >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'IPAddressDeny=any' ${unit}/bdday.service >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'IPAddressAllow=localhost' ${unit}/bdday.service >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'server_name bd.ablz.au;' ${nginxConfig} >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'proxy_pass http://127.0.0.1:8849;' ${nginxConfig} >/dev/null
      touch $out
    '';

  # Evaluated contract for the private Hugo site: immutable site
  # package, loopback-only static server, and LAN/tailnet HTTPS ingress.
  mrnewsIntegrationCheck = let
    doc1 = self.nixosConfigurations.proxmox-vm.config;
    sitePackage = inputs.mrnews.packages.${system}.default;
    mrnewsCfg = doc1.homelab.services.mrnews;
    service = doc1.systemd.services.mrnews.serviceConfig;
    unit = doc1.systemd.units."mrnews.service".unit;
    nginxConfig = doc1.environment.etc."nginx/nginx.conf".source;
    proxy = lib.findFirst (entry: entry.host == mrnewsCfg.fqdn) null doc1.homelab.localProxy.hosts;
    monitor = lib.findFirst (entry: entry.url == "https://${mrnewsCfg.fqdn}/") null doc1.homelab.monitoring.monitors;
    unrelatedEnabled = lib.filter (
      name: self.nixosConfigurations.${name}.config.homelab.services.mrnews.enable
    ) (lib.remove "proxmox-vm" (lib.attrNames self.nixosConfigurations));
    firewallText = lib.concatStringsSep "\n" [
      doc1.networking.firewall.extraCommands
      doc1.networking.firewall.extraInputRules
    ];
    expectedExecStart = lib.concatStringsSep " " [
      "${pkgs.static-web-server}/bin/static-web-server"
      "--host 127.0.0.1"
      "--port ${toString mrnewsCfg.port}"
      "--root ${sitePackage}"
      "--cache-control-headers false"
      "--log-level warn"
    ];
  in
    pkgs.runCommand "mrnews-integration" {} ''
      set -euo pipefail

      test '${lib.boolToString mrnewsCfg.enable}' = true
      test '${lib.boolToString (mrnewsCfg.package == sitePackage)}' = true
      test ${lib.escapeShellArg mrnewsCfg.fqdn} = mrnews.ablz.au
      test ${toString mrnewsCfg.port} -eq 8850
      test ${lib.escapeShellArg service.ExecStart} = ${lib.escapeShellArg expectedExecStart}
      test -s ${sitePackage}/index.html
      test -s ${sitePackage}/index.xml

      test '${lib.boolToString service.DynamicUser}' = true
      test '${lib.boolToString service.NoNewPrivileges}' = true
      test ${lib.escapeShellArg service.ProtectSystem} = strict
      test '${lib.boolToString service.ProtectHome}' = true
      test '${lib.boolToString service.PrivateTmp}' = true
      test '${lib.boolToString service.PrivateDevices}' = true
      test -z ${lib.escapeShellArg service.CapabilityBoundingSet}
      test -z ${lib.escapeShellArg service.AmbientCapabilities}
      test '${lib.boolToString service.RestrictNamespaces}' = true
      test ${lib.escapeShellArg service.IPAddressDeny} = any
      test ${lib.escapeShellArg service.IPAddressAllow} = localhost

      test '${lib.boolToString (proxy != null)}' = true
      test ${lib.escapeShellArg proxy.upstreamHost} = 127.0.0.1
      test ${toString proxy.port} -eq 8850
      test '${lib.boolToString (!proxy.tailscaleOnly)}' = true
      test '${lib.boolToString (lib.hasPrefix "192.168." doc1.homelab.localProxy.localIp)}' = true
      test ${lib.escapeShellArg doc1.services.nginx.virtualHosts.${mrnewsCfg.fqdn}.locations."/".proxyPass} = http://127.0.0.1:8850
      test ${lib.escapeShellArg doc1.services.nginx.virtualHosts.${mrnewsCfg.fqdn}.useACMEHost} = mrnews.ablz.au
      test '${lib.boolToString (builtins.hasAttr mrnewsCfg.fqdn doc1.security.acme.certs)}' = true
      ${pkgs.gnugrep}/bin/grep -F '"proxied":false' ${../../modules/nixos/services/local_proxy.nix} >/dev/null

      test '${lib.boolToString (monitor != null)}' = true
      test ${lib.escapeShellArg monitor.name} = 'Margaret River News'
      test '${lib.boolToString (!(lib.elem mrnewsCfg.port doc1.networking.firewall.allowedTCPPorts))}' = true
      test '${lib.boolToString (!(lib.elem mrnewsCfg.port doc1.networking.firewall.allowedUDPPorts))}' = true
      test '${lib.boolToString (!(lib.hasInfix (toString mrnewsCfg.port) firewallText))}' = true
      test -z ${lib.escapeShellArg (lib.concatStringsSep " " unrelatedEnabled)}

      ${pkgs.gnugrep}/bin/grep -F "ExecStart=${expectedExecStart}" ${unit}/mrnews.service >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'DynamicUser=true' ${unit}/mrnews.service >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'IPAddressDeny=any' ${unit}/mrnews.service >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'IPAddressAllow=localhost' ${unit}/mrnews.service >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'server_name mrnews.ablz.au;' ${nginxConfig} >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'proxy_pass http://127.0.0.1:8850;' ${nginxConfig} >/dev/null
      touch $out
    '';

  # Cullen's split-horizon bd route terminates at WSL but preserves
  # doc1 as the one bdday authority. Assert the generated vhost's
  # numeric upstream/SNI boundary and retain the independent Cullen
  # dashboard vhost.
  cullenBdProxyCheck = let
    wsl = self.nixosConfigurations.wsl.config;
    bdVhost = wsl.services.nginx.virtualHosts."bd.ablz.au";
    cullenVhost = wsl.services.nginx.virtualHosts."cullen.ablz.au";
    bdIsLocalProxyHost = lib.any (entry: entry.host == "bd.ablz.au") wsl.homelab.localProxy.hosts;
  in
    pkgs.runCommand "cullen-bd-proxy" {} ''
      set -euo pipefail

      test '${lib.boolToString (builtins.hasAttr "bd.ablz.au" wsl.security.acme.certs)}' = true
      test ${lib.escapeShellArg bdVhost.useACMEHost} = bd.ablz.au
      test ${lib.escapeShellArg bdVhost.locations."/".proxyPass} = https://192.168.1.29:443
      test '${lib.boolToString bdIsLocalProxyHost}' = false
      case ${lib.escapeShellArg bdVhost.locations."/".extraConfig} in
        *'proxy_ssl_server_name on;'*'proxy_ssl_name bd.ablz.au;'*'proxy_ssl_verify on;'*'proxy_ssl_trusted_certificate '*';'*'proxy_ssl_verify_depth 4;'*) ;;
        *) echo "bd proxy is missing its upstream TLS or Host boundary" >&2; exit 1 ;;
      esac

      test ${lib.escapeShellArg cullenVhost.useACMEHost} = cullen.ablz.au
      touch $out
    '';

  # WSL's mapped Z: drive can remain remembered but disconnected after
  # a Windows/WSL restart. The nightly sync must repair that Windows-side
  # mapping before treating its source as unavailable.
  wslOpsSyncSourceReconnectCheck = let
    wsl = self.nixosConfigurations.wsl.config;
    reconnect = wsl.systemd.services.ops-sync-source-reconnect.serviceConfig.ExecStart;
  in
    pkgs.runCommand "wsl-ops-sync-source-reconnect" {} ''
      reconnect=${lib.escapeShellArg reconnect}
      test ${lib.escapeShellArg wsl.homelab.mounts.opsSync.sourceWindowsShare} = '\\192.168.100.201\Data'
      test ${lib.escapeShellArg wsl.systemd.services.ops-sync-source-reconnect.serviceConfig.User} = nixos
      test '${lib.boolToString (lib.elem "mnt-z.automount" wsl.systemd.services.ops-sync.wants)}' = true
      ${pkgs.gnugrep}/bin/grep -F 'share_b64="$(printf' "$reconnect" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'WSLENV=OPS_SYNC_SHARE_B64' "$reconnect" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F '[Convert]::FromBase64String($env:OPS_SYNC_SHARE_B64)' "$reconnect" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F '$mapping = Get-SmbMapping -LocalPath "Z:"' "$reconnect" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F '$mapping.RemotePath -eq $ExpectedShare' "$reconnect" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'net.exe" use Z: /delete /y' "$reconnect" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'Start-Process -FilePath "$env:SystemRoot\System32\net.exe"' "$reconnect" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F '@("use", "Z:", $ExpectedShare, "/persistent:yes")' "$reconnect" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'Test-Path -LiteralPath "Z:\Operations & Production"' "$reconnect" >/dev/null
      ops_sync=${lib.escapeShellArg wsl.systemd.services.ops-sync.serviceConfig.ExecStart}
      ${pkgs.gnugrep}/bin/grep -F 'systemctl reset-failed mnt-z.mount' "$ops_sync" >/dev/null
      touch $out
    '';

  # Timer-driven cleanup commands must resolve to real executables in
  # the evaluated host closure. lib.getExe' does not validate that an
  # arbitrary package actually provides the requested binary.
  audiobookshelfCacheCleanupCheck = let
    command = self.nixosConfigurations.doc2.config.systemd.services.audiobookshelf-cache-cleanup.serviceConfig.ExecStart;
    executable = builtins.head (lib.splitString " " command);
  in
    pkgs.runCommand "audiobookshelf-cache-cleanup-executable" {} ''
      if [ ! -x ${lib.escapeShellArg executable} ]; then
        echo "Audiobookshelf cleanup ExecStart is not executable: ${executable}"
        exit 1
      fi
      touch $out
    '';

  # Keep the doc2 crash evidence path structurally independent of the
  # guest and lock the SSH-identity regression that broke the 2026-08-03
  # automatic reset. Generated scripts are checked, not only Nix source,
  # so interpolation/shadowing mistakes cannot hide behind evaluation.
  doc2CrashCaptureCheck = let
    doc2 = self.nixosConfigurations.doc2.config;
    observer = self.nixosConfigurations.proxmox-vm.config;
    recovery = observer.systemd.services.doc2-recovery.serviceConfig.ExecStart;
    receiverSync = observer.systemd.services.doc2-netconsole-prom-sync.serviceConfig.ExecStart;
    saveVmcore = doc2.systemd.services.crash-capture-save-vmcore.serviceConfig.ExecStart;
    dumpMount = doc2.systemd.services.crash-capture-save-vmcore.unitConfig.RequiresMountsFor;
    dumpFailureAction = doc2.systemd.services.crash-capture-save-vmcore.unitConfig.FailureAction;
    dumpTimeout = doc2.systemd.services.crash-capture-save-vmcore.serviceConfig.TimeoutStartSec;
    hasStaleDoc1Socket = observer.systemd.sockets ? doc2-netconsole;
  in
    pkgs.runCommand "doc2-crash-capture-invariants" {} ''
      recovery=${lib.escapeShellArg recovery}
      receiver_sync=${lib.escapeShellArg receiverSync}
      save_vmcore=${lib.escapeShellArg saveVmcore}

      ${pkgs.gnugrep}/bin/grep -F 'ssh -i "$ssh_key"' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'IdentitiesOnly=yes' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'StrictHostKeyChecking=yes' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'for sysrq_key in w t' "$recovery" >/dev/null
      if ${pkgs.gnugrep}/bin/grep -F 'ssh -i "$key"' "$recovery" >/dev/null; then
        echo "recovery script still permits the sysrq loop to overwrite its SSH identity"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -F 'info registers -a' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'qm pending $vmid' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'qm showcmd $vmid --pretty' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'captured-qga-only' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'recovered-during-capture' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'consecutive-dual-failures' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'last-observation' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'doc2_secondary_address' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'final_vm_pid' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'receiver-unhealthy' "$recovery" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'mktemp -d /run/doc2-netconsole-sync.XXXXXX' "$receiver_sync" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'StrictHostKeyChecking=yes' "$receiver_sync" >/dev/null
      if ${pkgs.gnugrep}/bin/grep -F '/tmp/doc2-netconsole-' "$receiver_sync" >/dev/null; then
        echo "receiver sync still stages privileged artifacts under shared /tmp"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -F 'fallocate -l "${"$"}{minimum_free_gib}G"' "$save_vmcore" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'deadline-exceeded' "$save_vmcore" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'configured_vmlinux=' "$save_vmcore" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'kernel-modules-' "$save_vmcore" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'partial="$target.partial"' "$save_vmcore" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'prune_generations' "$save_vmcore" >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'kill -KILL -- "-$gzip_pid"' "$save_vmcore" >/dev/null
      if ${pkgs.gnugrep}/bin/grep -F 'df -P' "$save_vmcore" >/dev/null; then
        echo "vmcore writer regressed to a polling-only free-space guard"
        exit 1
      fi

      test ${toString doc2.homelab.crashCapture.netconsole.collectorPort} -eq 6667
      test ${lib.boolToString doc2.homelab.crashCapture.kdump.enable} = true
      test ${toString doc2.homelab.crashCapture.kdump.maxDumpMinutes} -eq 15
      test ${lib.escapeShellArg dumpMount} = /var/crash
      test ${lib.escapeShellArg dumpFailureAction} = reboot-force
      test ${lib.escapeShellArg dumpTimeout} = 20min
      test ${toString observer.homelab.services.doc2Recovery.captureFailureThreshold} -eq 10
      test ${toString observer.homelab.services.doc2Recovery.resetFailureThreshold} -eq 25
      test ${toString doc2.boot.kernel.sysctl."kernel.panic_on_oops"} -eq 1
      test ${toString doc2.boot.kernel.sysctl."kernel.panic_print"} -eq 63
      test ${lib.boolToString hasStaleDoc1Socket} = false
      if ${pkgs.gnugrep}/bin/grep -F 'copytruncate' ${../../modules/nixos/services/doc2-recovery.nix} >/dev/null; then
        echo "netconsole rotation must use rename plus receiver reopen"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -F 'SO_RXQ_OVFL' ${../../modules/nixos/services/doc2-recovery.nix} >/dev/null
      ${pkgs.gnugrep}/bin/grep -F 'LogsDirectoryMode=0700' ${../../modules/nixos/services/doc2-recovery.nix} >/dev/null
      touch $out
    '';

  # Podman 6 cutover invariant (#13/#136). Every rootful Podman host must
  # move as one transaction: Podman 6, the Netavark/Aardvark 2.x line that
  # contains missing-netns teardown, native nftables, no legacy firewall
  # commands, and a pre-activation BoltDB refusal.
  podman6CutoverCheck = let
    rootfulPodmanHosts = lib.filterAttrs (_: cfg: cfg.config.virtualisation.podman.enable) self.nixosConfigurations;
    checkHost = name: cfg: let
      host = cfg.config;
      podmanVersion = cfg.pkgs.podman.version;
      netavarkVersion = cfg.pkgs.netavark.version;
      aardvarkVersion = cfg.pkgs.aardvark-dns.version;
      buildahVersion = cfg.pkgs.buildah.version;
      skopeoVersion = cfg.pkgs.skopeo.version;
      legacyFirewall = host.networking.firewall.extraCommands;
      nativeFirewall = host.networking.firewall.extraInputRules;
      podman = cfg.pkgs.podman;
      buildah = cfg.pkgs.buildah;
      guardPackage = host.homelab.podman.databaseBackendGuardPackage;
      activationGuard = host.system.activationScripts.podmanDatabaseBackendGuard;
      guard = activationGuard.text or "";
      guardUnit = "podman-database-backend-guard.service";
      lifecycleServiceNames =
        ["podman" "podman-prune"]
        ++ lib.optional (host.homelab.podman.containers != []) "podman-update-containers"
        ++ map (entry: lib.removeSuffix ".service" entry.unit) host.homelab.podman.containers;
      lifecycleGuarded =
        lib.all (
          serviceName:
            lib.elem guardUnit host.systemd.services.${serviceName}.requires
            && lib.elem guardUnit host.systemd.services.${serviceName}.after
        )
        lifecycleServiceNames;
      guardReachable = serviceName: let
        visit = seen: name:
          if lib.elem name seen || !(builtins.hasAttr name host.systemd.services)
          then false
          else let
            requiredUnits = host.systemd.services.${name}.requires or [];
            requiredServices = map (unit: lib.removeSuffix ".service" unit) requiredUnits;
          in
            lib.elem guardUnit requiredUnits
            || lib.any (visit ([name] ++ seen)) requiredServices;
      in
        visit [] serviceName;
      podmanServiceNames = lib.filter (
        serviceName:
          serviceName
          != "podman-database-backend-guard"
          && !(lib.hasSuffix "-nfs-watchdog" serviceName)
          && (serviceName == "podman" || lib.hasPrefix "podman-" serviceName)
      ) (builtins.attrNames host.systemd.services);
      allPodmanServicesGuarded = lib.all guardReachable podmanServiceNames;
      bootGuardExec = host.systemd.services.podman-database-backend-guard.serviceConfig.ExecStart;
      bootGuardMounts = host.systemd.services.podman-database-backend-guard.unitConfig.RequiresMountsFor;
      graphRoot = host.virtualisation.containers.storage.settings.storage.graphroot;
    in ''
      echo 'Checking Podman 6 cutover invariants on ${name}'
      test '${lib.versions.major podmanVersion}' = 6
      test '${lib.boolToString (lib.versionAtLeast netavarkVersion "2.1")}' = true
      test '${lib.boolToString (lib.versionOlder netavarkVersion "3")}' = true
      test '${lib.boolToString (lib.versionAtLeast aardvarkVersion "2")}' = true
      test '${lib.boolToString (lib.versionOlder aardvarkVersion "3")}' = true
      test '${lib.boolToString (lib.versionAtLeast buildahVersion "1.44")}' = true
      test '${lib.boolToString (lib.versionAtLeast skopeoVersion "1.23")}' = true
      test '${lib.boolToString host.networking.nftables.enable}' = true
      test '${lib.boolToString (lib.hasInfix ''iifname "podman*" meta l4proto { tcp, udp } th dport 53 accept'' nativeFirewall)}' = true
      test '${lib.boolToString lifecycleGuarded}' = true
      test '${lib.boolToString allPodmanServicesGuarded}' = true
      test '${lib.boolToString (lib.elem "specialfs" activationGuard.deps)}' = true
      test '${lib.boolToString (lib.elem graphRoot bootGuardMounts)}' = true
      test ${lib.escapeShellArg bootGuardExec} = ${lib.escapeShellArg "${guardPackage} ${graphRoot}"}
      test -z ${lib.escapeShellArg legacyFirewall}
      test "$(${pkgs.coreutils}/bin/readlink -f ${podman}/libexec/podman/netavark)" = '${cfg.pkgs.netavark}/bin/netavark'
      test "$(${pkgs.coreutils}/bin/readlink -f ${podman}/libexec/podman/aardvark-dns)" = '${cfg.pkgs.aardvark-dns}/bin/aardvark-dns'
      helper=$(${pkgs.binutils}/bin/strings ${buildah}/bin/buildah \
        | ${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-buildah-helper-binary-wrapper-[^/]*/bin' \
        | ${pkgs.coreutils}/bin/head -n 1)
      test "$(${pkgs.coreutils}/bin/readlink -f "$helper/netavark")" = '${cfg.pkgs.netavark}/bin/netavark'
      test "$(${pkgs.coreutils}/bin/readlink -f "$helper/aardvark-dns")" = '${cfg.pkgs.aardvark-dns}/bin/aardvark-dns'
      guard=${lib.escapeShellArg guard}
      test -n "$guard"
      printf '%s' "$guard" | ${pkgs.gnugrep}/bin/grep -F '${guardPackage}' >/dev/null
      graph_root="$TMPDIR/${name}-graph-root"
      mkdir -p "$graph_root/libpod"
      ${guardPackage} "$graph_root"
      touch "$graph_root/libpod/bolt_state.db"
      if ${guardPackage} "$graph_root"; then
        echo 'BoltDB guard accepted bolt_state.db on ${name}' >&2
        exit 1
      fi
    '';
  in
    pkgs.runCommand "podman6-cutover-invariants" {} ''
      set -euo pipefail
      for source in \
        ${self}/modules/nixos/homelab/podman.nix \
        ${self}/modules/nixos/services/loki.nix \
        ${self}/modules/nixos/services/mailsearch.nix \
        ${self}/modules/nixos/services/musicbrainz.nix
      do
        if ${pkgs.gnugrep}/bin/grep -Eq '(^|[[:space:]])(ip6?tables|extra(Stop)?Commands)[[:space:]=]' "$source"; then
          echo "legacy firewall command reintroduced in $source" >&2
          exit 1
        fi
      done
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList checkHost rootfulPodmanHosts)}
      touch $out
    '';

  cratediggerDailySummaryCheck = let
    notifier = self.nixosConfigurations.proxmox-vm.config.systemd.services.cratedigger-daily-checks-notify-failure.serviceConfig.ExecStart;
  in
    pkgs.runCommand "cratedigger-daily-summary" {
      nativeBuildInputs = [pkgs.gnugrep pkgs.jq pkgs.python3];
    } ''
      CRATEDIGGER_DAILY_SUMMARY=${../../modules/nixos/ci/scripts/cratedigger-daily-summary.py} \
        python3 ${./test_cratedigger_daily_summary.py}
      CRATEDIGGER_WORLD_AUDIT_PROTOCOL=${../../modules/nixos/ci/scripts/cratedigger-world-audit-protocol.jq} \
        python3 ${./test_cratedigger_world_audit_protocol.py}
      grep -q 'MONITOR_INVOCATION_ID' ${notifier}
      if grep -q 'systemctl show' ${notifier}; then
        echo "Cratedigger notifier must use the OnFailure invocation ID" >&2
        exit 1
      fi
      touch "$out"
    '';

  aliYotoZipCheck =
    pkgs.runCommand "ali-yoto-zip" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      ALI_YOTO_ZIP=${../../modules/nixos/services/ali-cratedigger/zip-albums.py} \
        python3 ${./test_ali_yoto_zip.py}
      touch "$out"
    '';

  aliCratediggerIntegrationCheck = let
    doc2 = self.nixosConfigurations.doc2.config;
    container = doc2.containers.ali-cratedigger;
    containerService = doc2.systemd.services."container@ali-cratedigger";
    share = doc2.homelab.tailscaleShare.ali-music;
    shareContainer = doc2.virtualisation.oci-containers.containers."ts-ali-music";
    yoto = doc2.homelab.services.yotoShare;
    firewallPorts = doc2.networking.firewall.interfaces.podman0.allowedTCPPorts;
    tmpfilesRules = doc2.systemd.tmpfiles.rules;
  in
    assert lib.assertMsg container.autoStart "Ali Cratedigger container must autostart";
    assert lib.assertMsg (!container.privateNetwork) "Ali Cratedigger requires the host network namespace for the private podman bridge gateway";
    assert lib.assertMsg (container.bindMounts."/mnt/virtio/music/slskd".hostPath == "/mnt/virtio/music/slskd") "Ali Cratedigger must share only the canonical slskd handoff";
    assert lib.assertMsg (container.bindMounts."/mnt/data/Media/Yoto/Music".hostPath == "/mnt/data/Media/Yoto/Music") "Ali's Beets library must be the Yoto Music publication tree";
    assert lib.assertMsg (container.bindMounts."/var/lib/postgresql".hostPath == "/var/lib/ali-cratedigger/postgresql") "Ali's PostgreSQL state must be independently persisted";
    assert lib.assertMsg (container.bindMounts."/run/cratedigger-secrets/PLEX_TOKEN".hostPath == "/run/cratedigger-secrets/PLEX_TOKEN") "Ali's notifier must consume the existing runtime Plex token";
    assert lib.assertMsg container.bindMounts."/run/cratedigger-secrets/PLEX_TOKEN".isReadOnly "Ali's Plex token must be mounted read-only";
    assert lib.assertMsg container.bindMounts."/run/beets".isReadOnly "Ali's Beets secret directory must be mounted read-only";
    assert lib.assertMsg (builtins.elem "beets-runtime-ready.service" containerService.requires && builtins.elem "cratedigger-secrets-split.service" containerService.requires) "Ali's container must require its rendered secrets";
    assert lib.assertMsg (builtins.elem "beets-runtime-ready.service" containerService.partOf && builtins.elem "cratedigger-secrets-split.service" containerService.partOf) "Ali's container must restart when a bound secret producer restarts";
    assert lib.assertMsg (share.upstream == "http://host.docker.internal:18088") "Ali's share must reach only the private bridge gateway";
    assert lib.assertMsg (share.tags == ["tag:share"]) "Ali's node must retain the default-deny share tag";
    assert lib.assertMsg (shareContainer.environment.TS_AUTH_ONCE == "true") "Persistent Tailscale shares must preserve their authenticated identity across restarts";
    assert lib.assertMsg (builtins.elem 18088 firewallPorts) "Ali's gateway must be admitted on podman0";
    assert lib.assertMsg (yoto.shareDir == "/mnt/data/Media/Yoto" && yoto.booksDir == "/mnt/data/Media/Yoto/Books") "Yoto must publish separate Books and Music roots";
    assert lib.assertMsg (builtins.elem "d /mnt/data/Media/Yoto 2755 99 100 -" tmpfilesRules) "The all-squash NFS Yoto root must retain the server's anonymous identity";
    assert lib.assertMsg (builtins.elem "d /mnt/data/Media/Yoto/Books 2755 99 100 -" tmpfilesRules) "The all-squash NFS Books root must retain the server's anonymous identity";
    assert lib.assertMsg (builtins.elem "d /mnt/data/Media/Yoto/Music 2775 99 100 -" tmpfilesRules) "The all-squash NFS Music root must retain the writable anonymous identity";
      pkgs.runCommand "ali-cratedigger-integration" {
        nativeBuildInputs = [pkgs.gnugrep];
      } ''
        test -e ${container.path}/etc/systemd/system/cratedigger.service
        test -e ${container.path}/etc/systemd/system/cratedigger-web.service
        test -e ${container.path}/etc/systemd/system/ali-yoto-zip.service
        beets_dir=$(grep -o '/nix/store/[^" ]*-ali-beets-config' ${container.path}/etc/systemd/system/ali-beets-catalog-ready.service)
        test -n "$beets_dir"
        grep -q '^library: /mnt/virtio/ali-cratedigger/beets-db/beets-library.db' "$beets_dir/config.yaml"
        redis_prep=$(grep -o '/nix/store/[^ ]*-redis-cratedigger-prep-conf' ${container.path}/etc/systemd/system/redis-cratedigger.service)
        redis_config=$(grep -o '"/nix/store/[^"]*-redis.conf"' "$redis_prep" | tr -d '"')
        grep -q '^bind 127.0.0.1' "$redis_config"
        grep -q '^port 6380' "$redis_config"
        postgres_prep=$(grep -o '/nix/store/[^ ]*-postgresql-pre-start' ${container.path}/etc/systemd/system/postgresql.service)
        postgres_config=$(grep -o '"/nix/store/[^"]*-postgresql.conf/postgresql.conf"' "$postgres_prep/bin/postgresql-pre-start" | tr -d '"')
        grep -q "^listen_addresses = 'localhost'" "$postgres_config"
        container_etc=$(readlink -f ${container.path}/etc)
        grep -q '^d /mnt/data/Media/Yoto/Music 2775 99 100 -$' "$container_etc/tmpfiles.d/00-nixos.conf"
        grep -q 'After=.*ali-beets-catalog-ready.service' ${container.path}/etc/systemd/system/cratedigger.service
        importer_unit=${container.path}/etc/systemd/system/cratedigger-importer.service
        importer=$(grep -o '/nix/store/[^ ]*-cratedigger-importer/bin/cratedigger-importer' "$importer_unit")
        test -n "$importer"
        config_file=$(grep -o '/nix/store/[^" ]*-cratedigger-config.ini' "$importer" | head -n1)
        test -n "$config_file"
        grep -q '^url = https://plex.ablz.au$' "$config_file"
        grep -q '^token_file = /run/cratedigger-secrets/PLEX_TOKEN$' "$config_file"
        grep -q '^library_section_id = 6$' "$config_file"
        grep -q '^path_map = /mnt/data/Media/Yoto/Music:/media3/Yoto/Music$' "$config_file"
        grep -q '127.0.0.1:18088' ${container.path}/etc/nginx/nginx.conf
        grep -q '10.88.0.1:18088' ${container.path}/etc/nginx/nginx.conf
        if grep -q '0.0.0.0:18088' ${container.path}/etc/nginx/nginx.conf; then
          echo 'Ali gateway widened beyond loopback and podman0' >&2
          exit 1
        fi
        touch "$out"
      '';

  cratediggerTipCanaryCheck = let
    systemd = self.nixosConfigurations.proxmox-vm.config.systemd;
    service = systemd.services.cratedigger-beets-tip-canary;
    dailyService = systemd.services.cratedigger-daily-checks;
    notifier = systemd.services.cratedigger-beets-tip-canary-notify-failure.serviceConfig.ExecStart;
    timer = systemd.timers.cratedigger-beets-tip-canary.timerConfig;
    dailyTimer = systemd.timers.cratedigger-daily-checks.timerConfig;
    dailyPath = lib.concatStringsSep ":" (map toString dailyService.path);
    tipPath = lib.concatStringsSep ":" (map toString service.path);
    dailyTmpfs = lib.toList dailyService.serviceConfig.TemporaryFileSystem;
  in
    pkgs.runCommand "cratedigger-tip-canary" {
      nativeBuildInputs = [pkgs.gnugrep];
    } ''
      case '${service.serviceConfig.ExecStart}' in
        *'/scripts/daily_beets_tip_update.sh') ;;
        *) echo "Beets tip canary must run only the tip candidate" >&2; exit 1 ;;
      esac
      grep -q 'MONITOR_INVOCATION_ID' ${notifier}
      grep -q 'cratedigger-beets-tip-canary.service' ${notifier}
      test '${service.environment.CRATEDIGGER_AUTOMATION_STATE_DIR}' = '/var/lib/cratedigger-daily-checks'
      test '${service.serviceConfig.StateDirectory}' = 'cratedigger-daily-checks'
      test '${dailyService.environment.GH_CONFIG_DIR}' != '${service.environment.GH_CONFIG_DIR}'
      test '${dailyService.environment.XDG_RUNTIME_DIR}' != '${service.environment.XDG_RUNTIME_DIR}'
      test '${dailyService.serviceConfig.RuntimeDirectory}' != '${service.serviceConfig.RuntimeDirectory}'
      test '${dailyService.serviceConfig.TimeoutStartSec}' = '17h'
      test '${service.serviceConfig.TimeoutStartSec}' = '17h'
      test '${toString (builtins.length dailyTmpfs)}' = '2'
      test '${toString (lib.count (entry: entry == "/mnt") dailyTmpfs)}' = '1'
      test '${toString (lib.count (entry: entry == "/run/cratedigger-daily-checks/scratch:rw,size=16G,nr_inodes=10000000,mode=0700,uid=1000,gid=100") dailyTmpfs)}' = '1'
      case '${dailyPath}' in *util-linux*) ;; *) echo "daily candidate lacks flock" >&2; exit 1 ;; esac
      case '${tipPath}' in *util-linux*) ;; *) echo "tip candidate lacks flock" >&2; exit 1 ;; esac
      test '${timer.OnCalendar}' = '*-*-* 18:05:00 Australia/Perth'
      test '${timer.OnCalendar}' != '${dailyTimer.OnCalendar}'
      touch "$out"
    '';

  ytDlpTipVersionCheck = let
    ytDlp = self.nixosConfigurations.proxmox-vm.pkgs.yt-dlp;
    shortRev = builtins.substring 0 7 inputs.yt-dlp-src.rev;
  in
    pkgs.runCommand "yt-dlp-tip-version" {
      nativeBuildInputs = [pkgs.python3Packages.packaging];
    } ''
      python -c 'from packaging.version import Version; Version("${ytDlp.version}")'
      case '${ytDlp.version}' in
        *'+git.${shortRev}') ;;
        *) echo 'yt-dlp version does not identify locked upstream tip ${shortRev}' >&2; exit 1 ;;
      esac
      touch "$out"
    '';

  # Every generated deep probe gets a separate calendar coordinator.
  # The ordinary interval timer must remain unchanged while the calendar
  # path waits boundedly for overlap and then starts/waits for the probe.
  postMaintenanceDeepProbeCheck = let
    probeSlug = name:
      lib.toLower (builtins.replaceStrings
        ["/" " " "(" ")" "—" "[" "]"]
        ["-" "-" "" "" "-" "" ""]
        name);
    probeCases = lib.concatMap (hostName: let
      host = self.nixosConfigurations.${hostName}.config;
    in
      map (probe: let
        slug = probeSlug probe.name;
      in {
        inherit hostName probe slug;
        timer = host.systemd.timers."deep-probe-${slug}".timerConfig;
        coordinatorTimer = host.systemd.timers."post-maintenance-deep-probe-${slug}".timerConfig;
        probeService = host.systemd.services."deep-probe-${slug}".serviceConfig;
        coordinatorService = host.systemd.services."post-maintenance-deep-probe-${slug}".serviceConfig;
      })
      host.homelab.monitoring.deepProbes)
    (lib.attrNames self.nixosConfigurations);
  in
    assert probeCases != [];
    assert lib.all (probeCase: lib.elem probeCase.probe.timeout ["60s" "300s"]) probeCases;
    assert lib.all (probeCase:
      builtins.removeAttrs probeCase.coordinatorService ["Environment" "TimeoutStartSec"]
      == builtins.removeAttrs probeCase.probeService ["Environment" "TimeoutStartSec"])
    probeCases;
    assert lib.all (probeCase:
      (probeCase.coordinatorService.Environment or [])
      == (probeCase.probeService.Environment or []) ++ ["POST_MAINTENANCE_DEEP_PROBE=1"])
    probeCases;
      pkgs.runCommand "post-maintenance-deep-probe-coordinators" {
        nativeBuildInputs = [pkgs.coreutils pkgs.gnugrep pkgs.util-linux];
      } ''
        ${lib.concatMapStringsSep "\n" (probeCase: ''
            test '${probeCase.timer.OnBootSec}' = '2m'
            test '${probeCase.timer.OnUnitActiveSec}' = '${probeCase.probe.interval}'
            test '${probeCase.timer.AccuracySec}' = '1s'
            test '${probeCase.timer.Unit}' = 'deep-probe-${probeCase.slug}.service'
            test '${probeCase.coordinatorTimer.OnCalendar}' = '*-*-* 05:31:00 Australia/Perth'
            test '${probeCase.coordinatorTimer.AccuracySec}' = '1s'
            test '${probeCase.coordinatorTimer.Unit}' = 'post-maintenance-deep-probe-${probeCase.slug}.service'
            test '${probeCase.coordinatorTimer.Unit}' != '${probeCase.timer.Unit}'
            test '${probeCase.probeService.Type}' = 'oneshot'
            test '${probeCase.coordinatorService.Type}' = 'oneshot'
            test '${probeCase.coordinatorService.ExecStart}' = '${probeCase.probeService.ExecStart}'
            test '${probeCase.coordinatorService.RuntimeDirectory}' = '${probeCase.probeService.RuntimeDirectory}'
            test -n '${probeCase.probeService.RuntimeDirectory}'
            test '${lib.boolToString probeCase.probeService.RuntimeDirectoryPreserve}' = 'true'
            test '${lib.boolToString probeCase.coordinatorService.RuntimeDirectoryPreserve}' = 'true'
            test '${probeCase.probeService.TimeoutStartSec}' = '${probeCase.probe.timeout}'
            test '${probeCase.probeService.TimeoutStopSec}' = '90s'
            test '${probeCase.coordinatorService.TimeoutStopSec}' = '90s'
            test '${probeCase.probeService.KillMode}' = 'control-group'
            test '${probeCase.coordinatorService.KillMode}' = 'control-group'
            test '${lib.boolToString probeCase.coordinatorService.NoNewPrivileges}' = 'true'
            test '${probeCase.coordinatorService.TimeoutStartSec}' = '15m'
            runner=${lib.escapeShellArg probeCase.probeService.ExecStart}
            ${pkgs.gnugrep}/bin/grep -F 'POST_MAINTENANCE_DEEP_PROBE' "$runner" >/dev/null
            ${pkgs.gnugrep}/bin/grep -F 'flock -w 480 9' "$runner" >/dev/null
            ${pkgs.gnugrep}/bin/grep -F 'flock -n 9' "$runner" >/dev/null
            ${pkgs.gnugrep}/bin/grep -F 'RUNTIME_DIRECTORY}/execution.lock' "$runner" >/dev/null
            printf '%s\n' ${lib.escapeShellArg (toString (probeCase.coordinatorService.Environment or []))} | ${pkgs.gnugrep}/bin/grep -F 'POST_MAINTENANCE_DEEP_PROBE=1' >/dev/null
            if printf '%s\n' ${lib.escapeShellArg (toString (probeCase.probeService.Environment or []))} | ${pkgs.gnugrep}/bin/grep -F 'POST_MAINTENANCE_DEEP_PROBE=1' >/dev/null; then
              echo 'ordinary probe unexpectedly carries post-maintenance mode' >&2
              exit 1
            fi
          '')
          probeCases}

        # Model a TERM-ignoring probe descendant that inherits fd 9. The
        # waiter must remain blocked after TERM, then acquire the lock
        # after the whole control group is KILLed at the explicit bound.
        lock="$TMPDIR/inherited-fd.lock"
        ready="$TMPDIR/holder-ready"
        acquired="$TMPDIR/waiter-acquired"
        cat > "$TMPDIR/holder" <<'EOF'
        #!/bin/sh
        exec 9>"$1"
        flock 9
        trap : TERM
        touch "$2"
        while :; do sleep 1; done
        EOF
        chmod +x "$TMPDIR/holder"
        setsid "$TMPDIR/holder" "$lock" "$ready" &
        holder=$!
        for _ in $(seq 1 50); do
          test -e "$ready" && break
          sleep 0.1
        done
        test -e "$ready"
        (
          exec 9>"$lock"
          flock -w 10 9
          touch "$acquired"
        ) &
        waiter=$!
        kill -TERM -- "-$holder"
        sleep 1
        test ! -e "$acquired"
        kill -KILL -- "-$holder"
        wait "$holder" 2>/dev/null || true
        wait "$waiter"
        test -e "$acquired"
        touch "$out"
      '';
in {
  inherit
    bddayIntegrationCheck
    mrnewsIntegrationCheck
    cullenBdProxyCheck
    wslOpsSyncSourceReconnectCheck
    audiobookshelfCacheCleanupCheck
    doc2CrashCaptureCheck
    podman6CutoverCheck
    cratediggerDailySummaryCheck
    aliYotoZipCheck
    aliCratediggerIntegrationCheck
    cratediggerTipCanaryCheck
    ytDlpTipVersionCheck
    postMaintenanceDeepProbeCheck
    ;
}
