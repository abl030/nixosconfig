{...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
  ];

  homelab.beets.enable = true;

  # doc1 is the sole writer to Forgejo master — gate pushes on the flake-check
  # audits so a policy violation can't reach master and break the nightly
  # rolling-flake-update. See modules/home-manager/services/git-prepush-audit.nix.
  homelab.gitPrePushAudit.enable = true;
}
