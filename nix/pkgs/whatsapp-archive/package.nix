# whatsapp-archive — receive-only WhatsApp archiver (whatsmeow -> SQLite).
# Go deps float: scripts/update_whatsapp_archive.sh bumps go.mod/go.sum and
# vendorHash nightly from rolling-flake-update, because WhatsApp logs out
# clients whose protocol version falls too far behind.
# Runbook: docs/wiki/services/whatsapp-archive.md
{pkgs}:
pkgs.buildGoModule {
  pname = "whatsapp-archive";
  version = "0.1.0";
  # Only the Go sources, so unrelated repo churn doesn't rebuild it.
  src = builtins.path {
    name = "whatsapp-archive-src";
    path = ./.;
    filter = path: _type: let
      base = baseNameOf path;
    in
      base == "go.mod" || base == "go.sum" || pkgs.lib.hasSuffix ".go" base;
  };
  vendorHash = "sha256-KW0HKi8ydHjlKdomOLholYjhqusyfLPj6N9M7LxyCRc=";
  # modernc.org/sqlite is pure Go.
  env.CGO_ENABLED = "0";
  ldflags = ["-s" "-w"];
  meta.mainProgram = "whatsapp-archive";
}
