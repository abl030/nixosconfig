# Only the local dashboard needs a managed app-server. Keep other commands,
# explicit remote connections and alternate Codex homes under caller control.
if [[ "${1:-}" == agents && "${CODEX_HOME:-$HOME/.codex}" == "@codexHome@" ]]; then
  for arg in "$@"; do
    case "$arg" in
      --remote|--remote=*|-h|--help)
        exec @codex@ "$@"
        ;;
    esac
  done

  : "${XDG_RUNTIME_DIR:?Codex agents requires a systemd user session}"
  @systemctl@ --user start codex-app-server.service
  exec @codex@ "$@" --remote "unix://$XDG_RUNTIME_DIR/codex-app-server/control.sock"
fi

exec @codex@ "$@"
