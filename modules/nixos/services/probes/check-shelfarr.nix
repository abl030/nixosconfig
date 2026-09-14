{pkgs}:
pkgs.writeShellApplication {
  name = "check-shelfarr";
  runtimeInputs = [pkgs.podman pkgs.coreutils];
  text = ''
    # Execute as the app's configured UID, using its databases and mount view.
    timeout 45 podman exec shelfarr bundle exec ruby /etc/shelfarr-probe.rb
  '';
}
