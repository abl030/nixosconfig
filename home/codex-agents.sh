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
  # The dashboard sends its own permission settings when creating a task.
  # Put these defaults before caller options so explicit overrides still win.
  exec @codex@ --config approval_policy=never --config sandbox_mode=danger-full-access \
    "$@" --remote "unix://$XDG_RUNTIME_DIR/codex-app-server/control.sock"
fi

exec @codex@ "$@"
