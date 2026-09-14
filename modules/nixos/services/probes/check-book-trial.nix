{pkgs}:
pkgs.writeShellApplication {
  name = "check-book-trial";
  runtimeInputs = [pkgs.podman (pkgs.python3.withPackages (ps: [ps.psycopg2 ps.pymysql]))];
  text = ''
    exec python3 ${./book-trial.py} "$@"
  '';
}
