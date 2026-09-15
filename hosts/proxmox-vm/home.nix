{pkgs, ...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
  ];

  home.packages = [
    pkgs.officecli
    (pkgs.python3.withPackages (pythonPackages: [pythonPackages.openpyxl]))
  ];

  # Dad's incoming NAS share needs doc1's private user-owned Tailscale daemon.
  # Account, host fingerprint and recovery: docs/wiki/services/dadnas.md.
  programs.ssh.matchBlocks.dadnas = {
    hostname = "100.103.36.101";
    user = "ibl";
    port = 22;
    identityFile = "~/.ssh/id_ed25519";
    forwardAgent = false;
    extraOptions = {
      IdentitiesOnly = "yes";
      ProxyCommand = "/run/wrappers/bin/sudo -n -u dadnas-tailnet ${pkgs.tailscale}/bin/tailscale --socket=/run/dadnas-tailnet/tailscaled.sock nc %h %p";
    };
  };

  # doc1 is the sole writer to Forgejo master. Audit-gate pushes (so a policy
  # violation can't reach master and break overnight's rolling-flake-update),
  # plus warn-only staged-file lint at commit time (decoupled from deploys).
  # See modules/home-manager/services/git-hooks.nix.
  homelab.gitHooks.enable = true;
}
