{...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
  ];

  # doc1 is the centralised Dolt SQL server for beads issue tracking
  homelab.claudeCode.doltServer = true;
}
