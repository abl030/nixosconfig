# Host Definitions & Fleet Trust
# ============================
#
# 1. Host Identity
#    The attribute name (e.g., "epimetheus") serves as the unique ID for the host.
#    The 'sshAlias' is used for SSH config shortcuts (e.g., `ssh epi`).
#    The 'hostname' must match the machine's actual hostname (for NixOS config).
#
# 2. Host Trust (Public Keys)
#    This file acts as the source of truth for the fleet's 'known_hosts'.
#    Each host entry must have a 'publicKey' attribute containing its
#    /etc/ssh/ssh_host_ed25519_key.pub.
#
# 3. Git Signing Trust
#    Hosts that can author fleet-valid commits declare signingKeys. The private
#    half is a local signing-only key on that machine; never authorize it for
#    SSH login and never copy it to another host. Non-host service principals
#    live in the reserved _signingPrincipals attr.
#
#    MANUAL KEY RETRIEVAL:
#    If the script fails, run this on the target host to get the string:
#      $ cat /etc/ssh/ssh_host_ed25519_key.pub
#
let
  # The single fleet identity. Its PRIVATE half lives ONLY on the doc1 bastion
  # (deployIdentity = true there, false everywhere else — see modules/nixos/
  # services/ssh/default.nix). Every non-bastion host trusts it so doc1 can
  # reach them; no sibling holds it, so a popped sibling can't move laterally.
  fleetIdentity = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity";

  # What every non-bastion (sibling) host trusts: the bastion's resident key
  # only. Phone + pihole keys deliberately excluded here — reach siblings via
  # the doc1 stepping-stone. See issue #270.
  fleetKeys = [fleetIdentity];

  # Phone (Termux on Galaxy A55) — separate identity, revocable if lost. Reaches
  # the doc1 bastion only; never a sibling. (Old root@pihole key dropped in #270.)
  phoneKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHmUU7BKMmjF53n0uCOg1w6uRe1erG13nembAiIE8ybN phone-fleet@s-a55";

  # doc1 bastion entry keys — per-device, passphrase-protected, also on GitHub.
  # Authorized on doc1 ONLY (the bastion's front door); siblings never trust these.
  bastionDeviceKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBl/6XgvT5NLe1R0Yu0Lduy/4nYnyDgAufGFppUJfUom abl030@epimetheus-bastion"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPyOTF8UNEwGkxNpzcdetGGShyX6aAG3BBk/8jLeCg11 abl030@framework-bastion"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEmXjAlxENRxMQ1qmw/K5nsLiHLFByywTqQdotRAye79 abl030@wsl-bastion"
  ];

  # doc1's front door trusts ONLY these: the per-device entry keys + the phone,
  # each pinned with from= so a key only works from inside the tailnet or home
  # LAN — never the open internet. No fleet key / pihole inbound. The passphrase
  # on each key is the real gate; from= bounds where it can be presented. #270.
  bastionFrom = ''from="100.64.0.0/10,192.168.1.0/24"'';
  bastionKeys = map (k: "${bastionFrom} ${k}") (bastionDeviceKeys ++ [phoneKey]);

  gitSigningKeys = {
    epimetheus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJbk76ibG3QuI4hpHytjt+fcib3DwS56/ZcRSL3+Rktq git-signing:epimetheus";
    framework = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIArtfNPWfiwfos9DXYYUE5nSNj2M0ALCz2TwU5NsxBjm git-signing:framework";
    wsl = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII5iTwmDvCAemE2p9vm0aOOj9oFnCwQZC9JQQAQnSnTE git-signing:wsl";
    proxmox-vm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIp/G54mPRjf5aZIZIrqFC065w1SHAz4oJethLkep0mO git-signing:proxmox-vm";
    nixBot = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOzUflpYoSH5vtyQiEYy4vI/KiCQqkpDKV9EtZMUvpZV git-signing:nix-bot";
  };
in {
  _signingPrincipals = [
    {
      principal = "nix bot <acme@ablz.au>";
      key = gitSigningKeys.nixBot;
    }
  ];

  epimetheus = {
    configurationFile = ./hosts/epi/configuration.nix;
    homeFile = ./hosts/epi/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "epimetheus";
    sshAlias = "epi";
    # Reach epi over its LAN IP, not the tailnet. The Tailscale ACL went
    # default-deny (#239, 2026-06-21) and doc1→epi tcp:22 isn't granted, so the
    # bare `epimetheus` MagicDNS name resolves to the (blocked) tailnet IP and
    # `ssh epi` hangs. The LAN path is fine; pin the matchBlock + known_hosts to
    # the IP. (Same sshHostName override the wsl entry uses for its forward.)
    sshHostName = "192.168.1.5";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGuTUS6W9BBOpoDWU7f1jUtlA3B1niCfEtuutfIKPYdr";
    authorizedKeys = fleetKeys;
    # forgejo#2: LOCKED by default (homelab.fleetDeploy.role defaults to
    # "locked" → no passwordless sudo; the passwordless nixos-rebuild grant in
    # configuration.nix is removed). Interactive workstation: abl030 has a
    # password = break-glass + interactive deploy path.
    signingKeys = [
      {
        principal = "abl030@epimetheus";
        key = gitSigningKeys.epimetheus;
      }
    ];
    syncthingDeviceId = "ZUEV7QP-JVG3ZE3-UIVJBSW-RMJ55TN-ZJRBGBX-5442PJS-3A2SMMI-RU7NAAX";
  };

  caddy = {
    homeFile = ./hosts/caddy/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "caddy";
    sshAlias = "cad";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGfVo+vSFpz+oRQqC+ZbGgDzJMRlmydMidZISurihzTZ";
    authorizedKeys = fleetKeys;
  };

  framework = {
    configurationFile = ./hosts/framework/configuration.nix;
    homeFile = ./hosts/framework/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030"; # keep as a plain string for Home Manager
    hostname = "framework";
    sshAlias = "fra";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP0atvH47232nLwq1b4P7583cj+WGJYHU4vx/4lgtNgl";
    authorizedKeys = fleetKeys;
    # forgejo#2: LOCKED by default (homelab.fleetDeploy.role defaults to
    # "locked" → no passwordless sudo; the passwordless nixos-rebuild grant in
    # configuration.nix removed). Laptop: abl030 has a password = break-glass +
    # interactive deploy path.
    signingKeys = [
      {
        principal = "abl030@framework";
        key = gitSigningKeys.framework;
      }
    ];
    syncthingDeviceId = "Z4IPNF4-564WG7C-IYNIPPN-WSQHH74-RCBMJV3-KIJ3PJT-KS4HBF3-JVDPWAY";
  };

  wsl = {
    configurationFile = ./hosts/wsl/configuration.nix;
    homeFile = ./hosts/wsl/home.nix;
    user = "nixos";
    homeDirectory = "/home/nixos";
    hostname = "wsl"; # Added to match ssh.nix
    sshAlias = "wsl"; # Added to match ssh.nix
    # The WSL VM has no Tailscale identity of its own; it's reached over the
    # tailnet at the WINDOWS host, which port-forwards its Tailscale-IP:22 into
    # the VM's sshd. `ssh wsl` therefore targets the Windows MagicDNS name, not
    # "wsl". The host key presented there is still this VM's (root@wsl), so the
    # publicKey below stays correct. See docs/wiki/infrastructure/wsl-tailscale-ssh.md
    sshHostName = "laptop-btibh4ie"; # Windows host MagicDNS name (Tailscale IP 100.75.246.114)
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFKj3zCDzBVEYSUTyCN4QIDU5S8uUP/NdPi0T8wk0HF root@wsl"; # <--- PASTE HERE
    authorizedKeys = fleetKeys;
    signingKeys = [
      {
        principal = "abl030@wsl";
        key = gitSigningKeys.wsl;
      }
    ];
    # forgejo#2: LOCKED by default (role defaults to "locked"). nixos has no
    # usable password here, so interactive sudo won't work until one is set —
    # but `wsl -u root` from Windows is always root with no password (the WSL
    # "console" break-glass), so this is NOT a hard lockout. To enable
    # interactive sudo: `wsl -u root passwd nixos`. Deploy via the nightly
    # nixos-upgrade timer or `wsl -u root fleet-update`; `fleet-deploy wsl` also
    # works once the widened triggerFrom (configuration.nix — the Windows
    # portproxy makes wsl's sshd see connections from the WSL bridge, not the
    # tailnet) has landed.
    syncthingDeviceId = "5HJSG3P-3LHIT3B-77EMHZP-FIOUOSN-FULX6IU-BQBGLNZ-UUJKAJM-Q67CHA2";
    # Windows host LAN IP at the Cullen office. Cloudflare A records for
    # services exposed via homelab.localProxy point here; Windows then
    # port-forwards 443 into the WSL VM's eth0.
    localIp = "192.168.100.128";
  };

  proxmox-vm = {
    configurationFile = ./hosts/proxmox-vm/configuration.nix;
    homeFile = ./hosts/proxmox-vm/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "proxmox-vm"; # Note: ssh.nix used "nixos", assuming "proxmox-vm" is the correct Tailscale name
    sshAlias = "doc1";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOJrhodI7gb1zaitbZayGHtpc+CO3MfFHK1+DG4Y6IZw root@nixos";
    # Step 4 (#270): doc1's front door = bastion keys ONLY (per-device entry keys
    # + phone, each from=-pinned to tailnet/LAN). No fleet/pihole inbound; the
    # fleet key it HOLDS (deployIdentity) is for reaching siblings, not entering.
    authorizedKeys = bastionKeys;
    # forgejo#2: the ONE bastion — passwordless sudo + the deploy-trigger key +
    # the `fleet-deploy` wrapper come from homelab.fleetDeploy.role = "bastion"
    # set in hosts/proxmox-vm/configuration.nix (the only host that may set it;
    # fleetBastionRoleCheck enforces exactly one).
    signingKeys = [
      {
        principal = "abl030@proxmox-vm";
        key = gitSigningKeys.proxmox-vm;
      }
    ];
    # Narrow Git ownership exemption for a single music-tagging workspace on the
    # shared media mount. This only suppresses Git's ownership guard for abl030's
    # doc1 Git CLI; it grants no filesystem access. Do not replace with a
    # wildcard: shared /mnt/data paths remain untrusted unless named here with a
    # path-specific rationale.
    gitSafeDirectories = ["/mnt/data/Media/Music/tagging-workspace"];
    syncthingDeviceId = "YQV3LUJ-MDJZYGB-7S7G3EM-DG6JFRV-SMBEGXH-OM2YYHE-63YVDT7-EE5YMAI";
    localIp = "192.168.1.29";
    tailscaleIp = "100.89.160.60";
  };

  igpu = {
    configurationFile = ./hosts/igpu/configuration.nix;
    homeFile = ./hosts/igpu/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "igpu";
    localIp = "192.168.1.33";
    tailscaleIp = "100.112.123.5";
    sshAlias = "igp";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPucrnfLpTjCzItnNPvGJ0iqQs2+iTyTXZH5pCBpuvDp root@nixos";
    authorizedKeys = fleetKeys;
    # forgejo#2: LOCKED by default (role defaults to "locked"). Deploys come from
    # doc1 via `fleet-deploy igpu` (forced-command key → nixos-upgrade, polkit, no
    # sudo). abl030 keeps only the role=locked read-only/deploy-hygiene allowlist.
    # abl030 has a password here (unlike doc2) so interactive sudo is the
    # break-glass; Proxmox console otherwise. No service/abl030 root pivot.
    syncthingDeviceId = "IJ3FS4G-DBM47AW-WEEM7W3-VCEOYP4-K6QRJLG-LHRZMJH-EMNN4IS-ZVHX6QF";
  };

  doc2 = {
    configurationFile = ./hosts/doc2/configuration.nix;
    homeFile = ./hosts/doc2/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "doc2";
    sshAlias = "doc2";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPv9MVIv00FafaGR/mPE3nW565bycshuwxlh3vhT+bZp";
    authorizedKeys = fleetKeys;
    # forgejo#2: LOCKED by default (role defaults to "locked"). No passwordless
    # sudo — abl030 has no password here either (`!`), so the only root abl030
    # keeps is the narrow read-only/deploy-hygiene allowlist (read-only podman +
    # deploy-switch-stop + podman-* restart; NOT journalctl — logs via Loki).
    # Deploys come from doc1 via `fleet-deploy doc2` (forced-command key →
    # nixos-upgrade, polkit, no sudo). Break-glass for anything else: the Proxmox
    # console on prom. A popped service/abl030 here can no longer pivot to root.
    localIp = "192.168.1.35";
    gotifyServer = true;
  };

  hermes = {
    configurationFile = ./hosts/hermes/configuration.nix;
    homeFile = ./hosts/hermes/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "hermes";
    sshAlias = "hermes";
    sshKeyName = "ssh_key_abl030";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMMJJaMvEpjESv/B83CpDuzeOlz/ur+Mw7WP3KaL2+cd root@hermes";
    # Keyless re: the fleet — trusts ONLY the doc1 bastion's resident key, so a
    # compromised agent VM cannot reach siblings. Reach hermes via doc1. #270.
    authorizedKeys = fleetKeys;
    # forgejo#2: LOCKED by default (role defaults to "locked"). Keyless,
    # Telegram-only agent VM on prom — abl030 has no password, prom console is
    # break-glass (like doc2). The agent container is unaffected (containers
    # don't use abl030 sudo). Deploy via `fleet-deploy hermes` from doc1.
    localIp = "192.168.1.162";
    tailscaleIp = "100.78.254.6";
  };

  # servarr — dedicated NixOS VM on tower for the *arr stack (Radarr / Sonarr /
  # Prowlarr), replacing the legacy Ubuntu `genericvm`. Takes 192.168.1.4 at
  # cutover. qBittorrent runs SEPARATELY in an isolated microvm.nix guest on
  # VLAN 20 (Torrent_DMZ) — see Forgejo issue #1. SCAFFOLD: not yet deployed;
  # publicKey filled after first boot (empty ⇒ excluded from fleet knownHosts).
  servarr = {
    configurationFile = ./hosts/servarr/configuration.nix;
    homeFile = ./hosts/servarr/home.nix;
    user = "abl030";
    homeDirectory = "/home/abl030";
    hostname = "servarr";
    sshAlias = "servarr";
    sshKeyName = "ssh_key_abl030";
    localIp = "192.168.1.4"; # target at cutover; build/test on a temp IP first
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL0GmBqKYliqhnLSAfQ6HMBT3M8lfg5yXtPd59bxIGnh root@servarr";
    authorizedKeys = fleetKeys; # fleet member: trusts ONLY the doc1 bastion key
  };
}
