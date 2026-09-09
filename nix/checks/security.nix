{
  self,
  lib,
  pkgs,
}: let
  # Lightweight text-based check: every service module declaring
  # `homelab.localProxy.hosts` must also declare
  # `homelab.monitoring.errorPatterns` (or an explicit empty list
  # with a justifying comment). Catches the omission introduced
  # in #253 — without an errorPatterns declaration the service's
  # real failure logs are invisible to alerting.
  errorPatternsCheck = pkgs.runCommand "errorPatterns-coverage" {} ''
    fail=0
    for f in ${../../modules/nixos/services}/*.nix; do
      base=$(basename "$f")
      if ${pkgs.gnugrep}/bin/grep -q "localProxy.hosts" "$f"; then
        if ! ${pkgs.gnugrep}/bin/grep -q "errorPatterns" "$f"; then
          echo "MISSING errorPatterns: $base declares localProxy.hosts but not homelab.monitoring.errorPatterns"
          fail=1
        fi
      fi
    done
    if [ $fail -ne 0 ]; then
      echo ""
      echo "Each module declaring localProxy.hosts must also declare"
      echo "homelab.monitoring.errorPatterns. Use \`errorPatterns = [];\`"
      echo "with a one-line justifying comment for services whose"
      echo "failure modes are genuinely covered by the Kuma HTTP"
      echo "monitor alone. See docs/wiki/nixos-service-modules.md"
      echo "\"Per-service errorPatterns\" section."
      exit 1
    fi
    echo "All service modules with localProxy.hosts declare errorPatterns."
    touch $out
  '';

  # All-interface bind audit (#232 Tier-3). A service that binds 0.0.0.0
  # is reachable, unauthenticated, by the WHOLE TAILNET — tailscale0 is a
  # trusted firewall interface (modules/nixos/services/tailscale), so an
  # all-interfaces bind sails past the localProxy nginx that's supposed to
  # front it (auth, rate-limit, ACL) and past any LAN-scoped firewalling.
  # Empirically verified 2026-06-19: doc2:8888/2283/3001 answered over the
  # tailnet IP. Default is 127.0.0.1 + homelab.localProxy.hosts. A
  # genuinely off-host endpoint (ingest, scrape target, fleet write root)
  # must carry a `BIND-ALL-INTERFACES-OK` marker comment saying why and how
  # exposure is otherwise scoped. The detector ignores comment lines (so a
  # comment that merely mentions 0.0.0.0 is fine) and CIDRs (…/0).
  hostBindAuditCheck = pkgs.runCommand "host-bind-audit" {} ''
    fail=0
    for f in $(${pkgs.findutils}/bin/find ${../../modules/nixos/services} -name '*.nix' | sort); do
      if ${pkgs.gnugrep}/bin/grep -vE '^[[:space:]]*#' "$f" \
           | ${pkgs.gnugrep}/bin/grep -oE '0\.0\.0\.0[^/]' >/dev/null 2>&1; then
        if ! ${pkgs.gnugrep}/bin/grep -q 'BIND-ALL-INTERFACES-OK' "$f"; then
          echo "UNJUSTIFIED all-interface bind: $(basename "$f")"
          fail=1
        fi
      fi
    done
    if [ $fail -ne 0 ]; then
      echo ""
      echo "A service module binds 0.0.0.0 (all interfaces). Because tailscale0"
      echo "is a trusted firewall interface, that exposes the service to the"
      echo "whole tailnet, unauthenticated, bypassing the localProxy nginx."
      echo "Fix: bind 127.0.0.1 and surface via homelab.localProxy.hosts."
      echo "If it genuinely must be reached off-host (ingest/scrape target,"
      echo "fleet write root), add a 'BIND-ALL-INTERFACES-OK' marker comment"
      echo "stating why and how exposure is scoped (firewall/auth)."
      echo "See docs/wiki/nixos-service-modules.md \"Host binding\" section."
      exit 1
    fi
    echo "All service-module 0.0.0.0 binds are justified (BIND-ALL-INTERFACES-OK)."
    touch $out
  '';

  # Per-unit NoNewPrivileges baseline (#232 host-hardening). NNP is a
  # PER-UNIT serviceConfig flag, so — unlike the centralized sysctl/sshd
  # baseline in base.nix — a brand-new service module silently skips it
  # unless something forces the decision. This check is that forcing
  # function: any module under modules/nixos/services/ that AUTHORS a unit
  # (an `ExecStart`/`script`/`preStart =` it owns) must either set
  # `NoNewPrivileges` (= true on every unit it can) or carry a
  # `# NNP-OK:` marker explaining why a unit legitimately needs to gain
  # privileges (e.g. tailscaled = privileged net daemon; OCI containers
  # already get no-new-privileges via homelab.podman hardenOptions; a unit
  # that activates the system / execs a setuid helper). File-level (like
  # the bind/network checks): catches the new unit that ships with no NNP
  # decision at all. lib/ + autoupdate/ infra units are out of scope (not
  # a growth surface); they carry markers for documentation only.
  unitHardeningAuditCheck = pkgs.runCommand "unit-hardening-audit" {} ''
    fail=0
    for f in $(${pkgs.findutils}/bin/find ${../../modules/nixos/services} -name '*.nix' | sort); do
      # Only units we AUTHOR (`ExecStart =`/`script =`). A bare
      # ExecStartPre/preStart usually just augments an UPSTREAM unit whose
      # serviceConfig (incl. NNP) we don't own — don't force a decision there.
      if ${pkgs.gnugrep}/bin/grep -vE '^[[:space:]]*#' "$f" \
           | ${pkgs.gnugrep}/bin/grep -qE '(ExecStart[[:space:]]*=|^[[:space:]]*script[[:space:]]*=)' ; then
        if ! ${pkgs.gnugrep}/bin/grep -q 'NoNewPrivileges' "$f" \
           && ! ${pkgs.gnugrep}/bin/grep -q 'NNP-OK' "$f"; then
          echo "unit without NoNewPrivileges decision: $(basename "$f")"
          fail=1
        fi
      fi
    done
    if [ $fail -ne 0 ]; then
      echo ""
      echo "A service module authors a systemd unit but makes no"
      echo "NoNewPrivileges decision. NNP is per-unit, so new units silently"
      echo "skip it as the fleet grows. Fix: set"
      echo "  serviceConfig.NoNewPrivileges = true;"
      echo "on every unit that doesn't legitimately need to gain privileges."
      echo "If a unit MUST (privileged daemon, system activation, setuid"
      echo "helper, or an OCI container hardened at the podman layer), add a"
      echo "'# NNP-OK: <reason>' marker comment. See"
      echo "docs/wiki/nixos-service-modules.md \"NoNewPrivileges\" section."
      exit 1
    fi
    echo "All unit-authoring service modules set NoNewPrivileges or are marked."
    touch $out
  '';

  # Per-service container network isolation (#232). Standalone OCI
  # containers must NOT share the default podman bridge (where every
  # container can L3-reach + DNS-resolve every other on 10.88.0.0/16, a
  # lateral-movement surface). The cure is structural: register the
  # container in `homelab.podman.containers`, which auto-assigns it a
  # dedicated `isolated-<name>` bridge (see modules/nixos/homelab/podman.nix)
  # AND gives it auto-update + autoheal. So every module that defines a
  # `virtualisation.oci-containers.containers` must either register it, or
  # carry a `CONTAINER-NETWORK-OK` marker documenting a deliberate bespoke
  # model (e.g. tailscale-share's shared-netns sidecars, hermes' single-
  # tenant VM). Catches a new container silently landing on the default bridge.
  containerNetworkAuditCheck = pkgs.runCommand "container-network-audit" {} ''
    fail=0
    for f in $(${pkgs.findutils}/bin/find ${../../modules/nixos/services} -name '*.nix' | sort); do
      if ${pkgs.gnugrep}/bin/grep -q 'oci-containers\.containers' "$f"; then
        if ! ${pkgs.gnugrep}/bin/grep -qE 'podman\.containers = \[' "$f" \
           && ! ${pkgs.gnugrep}/bin/grep -q 'CONTAINER-NETWORK-OK' "$f"; then
          echo "OCI container not isolated: $(basename "$f")"
          fail=1
        fi
      fi
    done
    if [ $fail -ne 0 ]; then
      echo ""
      echo "A module defines an OCI container that neither registers in"
      echo "homelab.podman.containers (which auto-assigns a dedicated"
      echo "isolated-<name> bridge + auto-update + autoheal) nor declares a"
      echo "bespoke network model. On the shared default podman bridge a"
      echo "compromised container can L3-pivot to every sibling. Fix: add the"
      echo "container to homelab.podman.containers. If it genuinely needs a"
      echo "custom network model, add a 'CONTAINER-NETWORK-OK' marker comment"
      echo "explaining it. See docs/wiki/nixos-service-modules.md \"Host binding\""
      echo "/ Podman section."
      exit 1
    fi
    echo "All OCI-container modules are registered (auto-isolated) or marked."
    touch $out
  '';

  # Least-privilege sops invariant (#234): every secret under
  # secrets/hosts/<H>/ must be encrypted to EXACTLY {that host's age key,
  # editor, break-glass} — never a sibling host key. Grep over the
  # plaintext age-recipient stanzas (works for dotenv/yaml/binary alike;
  # no decryption needed). Catches a re-key that strands a host (missing
  # own key) or leaks a host-dir secret to a sibling. The recipient↔host
  # map below mirrors secrets/.sops.yaml.
  sopsRecipientScopeCheck = pkgs.runCommand "sops-recipient-scope" {} ''
    grep=${pkgs.gnugrep}/bin/grep
    ed=age17uw7vxe8x3nmg0lu5j33qlh8pxr538jlqhhjngmexdc0macccg8sc8rw63
    bg=age1y6nasu9gplutapjne4yv0uhzrwee6ayf2mygwhphf3nty6x5xddqy4zl4h
    doc1=age1y4sdqs8dnlrma395hjna6dmzcctaeqpr8rh0wx6ap626uv0mremqsgdn30
    doc2=age1w09y86s3rtp8f06rfrwx865p9nrxsklhlsf03qsqmrlpcudleplq26xujh
    igpu=age1qa8d22yxg78e74a433vh0laaqmjp7wdx0jw0g40wfvt8ngvttdhs5c6z4c
    epi=age1gr4papzzdqfxd34ushr88303f2ypdwvgx9cw2xqs87yn4zf8lpxqc0rur5
    fw=age1ysfdznu87vwwqtpudchkyx0wlhuhteqljrqkt6963pcmhwprlgcqasg0gv
    wsl=age10hqxw3uxvg9nkc56rm495ty0rge0yhkcqp95gx00tgsv8ptg93mqwywlja
    servarr=age1tdnkggnfqkav7zxw5r3ty4d8r0tavk34p8aclzmkdtzjp69smpusudf2k4
    musicbrainz=age1cde5nfss8lkstnpe5qjq357hw253lk5sedtpznulnq5gllsc33lsll5rrl
    discogs=age12u5yjh0wff8y2tdfx5yzewrpqnhadlrafhmmmctsy37vnu8mgdlsz2p7wc
    imagegengpu=age19smw6a5ay9he8e82maght65wrh368ef7jakxpf937hwh4h4esqaqswe457
    allhosts="$doc1 $doc2 $igpu $epi $fw $wsl $servarr $musicbrainz $discogs $imagegengpu"
    fail=0
    for d in ${../../secrets/hosts}/*/; do
      h=$(basename "$d")
      case "$h" in
        proxmox-vm) own=$doc1 ;;
        doc2) own=$doc2 ;;
        igpu) own=$igpu ;;
        epimetheus) own=$epi ;;
        framework) own=$fw ;;
        wsl) own=$wsl ;;
        servarr) own=$servarr ;;
        musicbrainz) own=$musicbrainz ;;
        discogs) own=$discogs ;;
        *) echo "unknown host dir: $h"; fail=1; continue ;;
      esac
      for f in "$d"*; do
        [ -f "$f" ] || continue
        case "$f" in *.pub) continue ;; esac
        for k in $allhosts; do
          [ "$k" = "$own" ] && continue
          if $grep -q "$k" "$f"; then echo "LEAK: hosts/$h/$(basename "$f") is encrypted to a sibling host key"; fail=1; fi
        done
        $grep -q "$own" "$f" || { echo "MISSING own-host key: hosts/$h/$(basename "$f")"; fail=1; }
        $grep -q "$ed" "$f" || { echo "MISSING editor key: hosts/$h/$(basename "$f")"; fail=1; }
        $grep -q "$bg" "$f" || { echo "MISSING break-glass key: hosts/$h/$(basename "$f")"; fail=1; }
      done
    done
    f=${../../secrets/ntfy-server.env}
    for k in $allhosts; do
      [ "$k" = "$doc2" ] && continue
      if $grep -q "$k" "$f"; then echo "LEAK: ntfy-server.env is encrypted to a non-doc2 host key"; fail=1; fi
    done
    $grep -q "$doc2" "$f" || { echo "MISSING doc2 key: ntfy-server.env"; fail=1; }
    $grep -q "$ed" "$f" || { echo "MISSING editor key: ntfy-server.env"; fail=1; }
    $grep -q "$bg" "$f" || { echo "MISSING break-glass key: ntfy-server.env"; fail=1; }
    if [ $fail -ne 0 ]; then
      echo ""
      echo "sops recipient scope violated (#234): every secrets/hosts/<H>/ secret"
      echo "must be encrypted to EXACTLY {that host key, editor, break-glass}."
      echo "Re-key with 'sops updatekeys' after fixing secrets/.sops.yaml. See"
      echo "docs/wiki/infrastructure/sops-break-glass-recovery.md."
      exit 1
    fi
    echo "sops recipient scope OK: every hosts/<H>/ secret is host-scoped."
    touch $out
  '';

  # Credential-to-argv ratchet (#49). Audit both authored source and the
  # evaluated systemd contracts. The unit text catches changes hidden by
  # Nix rendering; deterministic known-bad fixtures qualify every owned
  # detector before the real files are scanned.
  secretArgvAuditCheck = let
    discogsSystemd = self.nixosConfigurations.discogs.config.systemd;
    doc2Systemd = self.nixosConfigurations.doc2.config.systemd;
    renderedContracts = pkgs.writeText "secret-argv-rendered-contracts" (lib.concatStringsSep "\n" [
      discogsSystemd.units."discogs-api.service".text
      discogsSystemd.units."discogs-import.service".text
      doc2Systemd.services."kopia-mum".script
      doc2Systemd.services."kopia-photos".script
    ]);
    renderedKopiaExecutables = [
      doc2Systemd.services."kopia-mum-source-sync".serviceConfig.ExecStart
      doc2Systemd.services."kopia-photos-source-sync".serviceConfig.ExecStart
      doc2Systemd.services."deep-probe-kopia-mum-freshness".serviceConfig.ExecStart
      doc2Systemd.services."deep-probe-kopia-mum-backup".serviceConfig.ExecStart
      doc2Systemd.services."deep-probe-kopia-photos-freshness".serviceConfig.ExecStart
      doc2Systemd.services."deep-probe-kopia-photos-backup".serviceConfig.ExecStart
      "${pkgs.callPackage ../../modules/nixos/services/probes/check-kopia-fresh.nix {}}/bin/check-kopia-fresh"
      "${pkgs.callPackage ../../modules/nixos/services/probes/check-kopia-backup-errors.nix {}}/bin/check-kopia-backup-errors"
    ];
  in
    pkgs.runCommand "secret-argv-audit" {
      nativeBuildInputs = [pkgs.python3 pkgs.gnugrep];
    } ''
      SECRET_ARGV_AUDIT=${./secret-argv-audit.py} \
        python3 ${./test_secret_argv_audit.py}
      bash ${./test-kopia-curl-auth.sh} \
        ${../../modules/nixos/services/probes/kopia-curl-auth.sh}
      python3 ${./secret-argv-audit.py} \
        ${renderedContracts} \
        ${lib.escapeShellArgs renderedKopiaExecutables} \
        ${../../modules/nixos/services/discogs.nix} \
        ${../../modules/nixos/services/kopia.nix} \
        ${../../modules/nixos/services/probes/check-kopia-fresh.nix} \
        ${../../modules/nixos/services/probes/check-kopia-backup-errors.nix}

      test "$(grep -c -- '--credential-file %d/postgres-password' ${renderedContracts})" -eq 2
      test "$(grep -c '^LoadCredential=postgres-password:' ${renderedContracts})" -eq 2
      if grep -q '^EnvironmentFile=.*discogs-pgpass' ${renderedContracts}; then
        echo "Discogs must not receive its PostgreSQL password through the environment" >&2
        exit 1
      fi
      touch "$out"
    '';
in {
  inherit
    errorPatternsCheck
    hostBindAuditCheck
    unitHardeningAuditCheck
    containerNetworkAuditCheck
    sopsRecipientScopeCheck
    secretArgvAuditCheck
    ;
}
