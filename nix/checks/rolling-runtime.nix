{
  self,
  lib,
  pkgs,
}: {
  rollingRuntimeDependencies = let
    updater = self.nixosConfigurations.proxmox-vm.config.systemd.services.rolling-flake-update;
  in
    pkgs.runCommand "rolling-runtime-dependencies" {} ''
      export PATH=${lib.makeBinPath updater.path}
      printf 'archive fixture\n' > fixture
      tar -czf fixture.tgz fixture
      tar -tzf fixture.tgz | grep -qx fixture
      touch "$out"
    '';

  homeOverlaySingleApplication = let
    matches = lib.all (
      home:
        map toString home.pkgs.gnome-shell.patches
        == map toString pkgs.gnome-shell.patches
        && map toString home.pkgs.slskd.patches == map toString pkgs.slskd.patches
    ) (builtins.attrValues self.homeConfigurations);
  in
    assert lib.assertMsg matches "Standalone Home Manager must not reapply the already-installed overlays";
      pkgs.runCommand "home-overlay-single-application" {} ''touch "$out"'';
}
