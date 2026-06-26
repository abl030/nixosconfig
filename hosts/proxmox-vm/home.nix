{...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
  ];

  homelab.beets.enable = true;

  # doc1 is the sole writer to Forgejo master. Audit-gate pushes (so a policy
  # violation can't reach master and break overnight's rolling-flake-update),
  # plus warn-only staged-file lint at commit time (decoupled from deploys).
  # See modules/home-manager/services/git-hooks.nix.
  homelab.gitHooks.enable = true;
}
