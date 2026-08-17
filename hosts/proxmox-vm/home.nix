{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
  ];

  home.packages = [
    pkgs.officecli
    (pkgs.python3.withPackages (pythonPackages: [pythonPackages.openpyxl]))
  ];

  # Agent output can contain very wide lines, so the shared 50k-line scrollback
  # grew tmux itself to 31 GiB. Keep useful history while bounding doc1's bastion.
  programs.tmux.historyLimit = lib.mkForce 10000;

  # doc1 is the sole writer to Forgejo master. Audit-gate pushes (so a policy
  # violation can't reach master and break overnight's rolling-flake-update),
  # plus warn-only staged-file lint at commit time (decoupled from deploys).
  # See modules/home-manager/services/git-hooks.nix.
  homelab.gitHooks.enable = true;
}
