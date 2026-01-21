#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<USAGE
Usage: $0 [--timeout SECONDS] [--verbose] <stack-dir> [compose-file]
USAGE
  exit 1
}

verbose=0
timeout_s=""
retries=3
backoff_base=30
prune_before=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      timeout_s="${2:-}"
      [[ -z "$timeout_s" ]] && usage
      shift 2;;
    --retries)
      retries="${2:-}"
      [[ -z "$retries" ]] && usage
      shift 2;;
    --backoff)
      backoff_base="${2:-}"
      [[ -z "$backoff_base" ]] && usage
      shift 2;;
    --no-prune)
      prune_before=0; shift;;
    --verbose)
      verbose=1; shift;;
    --help|-h)
      usage;;
    *)
      break;;
  esac
done

after_args=("$@")
if [[ ${#after_args[@]} -lt 1 ]]; then
  usage
fi

stack_dir="${after_args[0]}"
compose_file="${after_args[1]:-$stack_dir/docker-compose.yml}"

if [[ ! -d "$stack_dir" ]]; then
  echo "Stack directory not found: $stack_dir" >&2
  exit 1
fi

if [[ ! -f "$compose_file" ]]; then
  echo "Compose file not found: $compose_file" >&2
  exit 1
fi

stack_dir_abs="$(cd "$stack_dir" && pwd)"
compose_file_abs="$(cd "$(dirname "$compose_file")" && pwd)/$(basename "$compose_file")"
export COMPOSE_FILE_ABS="$compose_file_abs"

if [[ -z "${CADDY_FILE:-}" && -f "${stack_dir_abs}/Caddyfile" ]]; then
  export CADDY_FILE="${stack_dir_abs}/Caddyfile"
fi
if [[ -z "${TAILSCALE_JSON:-}" ]]; then
  if [[ -f "${stack_dir_abs}/immich-tailscale-serve.json" ]]; then
    export TAILSCALE_JSON="${stack_dir_abs}/immich-tailscale-serve.json"
  elif [[ -f "${stack_dir_abs}/tailscale-serve.json" ]]; then
    export TAILSCALE_JSON="${stack_dir_abs}/tailscale-serve.json"
  fi
fi

project_name="${COMPOSE_PROJECT_NAME:-$(basename "$stack_dir_abs")}"
project_name="$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]')"

data_root="${DATA_ROOT:-$HOME/podman-data}"

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

test_root="${TEST_MOUNTS_ROOT:-$HOME/.podman-test-mounts/$project_name}"
export MEDIA_ROOT="${MEDIA_ROOT:-$test_root/data}"
export FUSE_ROOT="${FUSE_ROOT:-$test_root/fuse}"
export MUM_ROOT="${MUM_ROOT:-$test_root/mum}"
export UNRAID_ROOT="${UNRAID_ROOT:-$test_root/unraid}"
export CONTAINERS_ROOT="${CONTAINERS_ROOT:-$test_root/containers}"
export NICOTINE_ROOT="${NICOTINE_ROOT:-$test_root/nicotine-plus}"
export PAPERLESS_ROOT="${PAPERLESS_ROOT:-$test_root/paperless}"

export PUID="${PUID:-$(id -u)}"
export PGID="${PGID:-$(id -g)}"
export POSTGRES_USER="${POSTGRES_USER:-test}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-testpass}"
export POSTGRES_DB="${POSTGRES_DB:-testdb}"
export DB_NAME="${DB_NAME:-testdb}"
export DB_USER="${DB_USER:-testuser}"
export DB_PASSWORD="${DB_PASSWORD:-testpass}"
export DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-rootpass}"
export DB_USERNAME="${DB_USERNAME:-testuser}"
export DB_DATABASE_NAME="${DB_DATABASE_NAME:-testdb}"
export DB_DATA_LOCATION="${DB_DATA_LOCATION:-$data_root/testdb}"
export APP_KEY="${APP_KEY:-testkey}"
export ATUIN_DB_NAME="${ATUIN_DB_NAME:-atuin}"
export ATUIN_DB_USERNAME="${ATUIN_DB_USERNAME:-atuin}"
export ATUIN_DB_PASSWORD="${ATUIN_DB_PASSWORD:-atuinpass}"
export KOPIA_SERVER_USER="${KOPIA_SERVER_USER:-kopia}"
export KOPIA_SERVER_PASSWORD="${KOPIA_SERVER_PASSWORD:-kopiapass}"
export KOPIA_PASSWORD="${KOPIA_PASSWORD:-kopiapass}"
export KUMA_USERNAME="${KUMA_USERNAME:-admin}"
export KUMA_PASSWORD="${KUMA_PASSWORD:-admin}"
export JELLYSTAT_DB_PASSWORD="${JELLYSTAT_DB_PASSWORD:-jellystatpass}"
export JELLYSTAT_JWT_SECRET="${JELLYSTAT_JWT_SECRET:-jellystatsecret}"
export DOCSPELL_SERVER_ADMIN__ENDPOINT_SECRET="${DOCSPELL_SERVER_ADMIN__ENDPOINT_SECRET:-docspelladminsecret}"
export DOCSPELL_SERVER_AUTH_SERVER__SECRET="${DOCSPELL_SERVER_AUTH_SERVER__SECRET:-docspellauthsecret}"
export DOCSPELL_SERVER_BACKEND_SIGNUP_MODE="${DOCSPELL_SERVER_BACKEND_SIGNUP_MODE:-open}"
export DOCSPELL_SERVER_BACKEND_SIGNUP_NEW__INVITE__PASSWORD="${DOCSPELL_SERVER_BACKEND_SIGNUP_NEW__INVITE__PASSWORD:-invitepass}"
export DOCSPELL_SERVER_INTEGRATION__ENDPOINT_HTTP__HEADER_HEADER__VALUE="${DOCSPELL_SERVER_INTEGRATION__ENDPOINT_HTTP__HEADER_HEADER__VALUE:-integrationsecret}"
export FIREFLY_III_ACCESS_TOKEN="${FIREFLY_III_ACCESS_TOKEN:-fireflytoken}"
export FF_DB_NAME="${FF_DB_NAME:-firefly}"
export FF_DB_USER="${FF_DB_USER:-firefly}"
export FF_DB_PASS="${FF_DB_PASS:-fireflypass}"
export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-token}"
export CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN:-token}"
export STATIC_CRON_TOKEN="${STATIC_CRON_TOKEN:-token}"
export WEBDAV_USERNAME="${WEBDAV_USERNAME:-user}"
export WEBDAV_PASSWORD="${WEBDAV_PASSWORD:-pass}"
export TS_HEALTHCHECK_ONLINE="${TS_HEALTHCHECK_ONLINE:-0}"
export ZO_ROOT_USER_EMAIL="${ZO_ROOT_USER_EMAIL:-zo@example.com}"
export ZO_ROOT_USER_PASSWORD="${ZO_ROOT_USER_PASSWORD:-zopass}"
export HEALTH_FILE="${HEALTH_FILE:-/tmp/health}"
export HEALTH_INTERVAL="${HEALTH_INTERVAL:-30s}"
export HEALTH_WINDOW="${HEALTH_WINDOW:-120s}"
export UPLOAD_LOCATION="${UPLOAD_LOCATION:-$data_root/uploads}"
export ROOT_MOVIES="${ROOT_MOVIES:-$FUSE_ROOT/Media/Movies}"
export ROOT_TV="${ROOT_TV:-$FUSE_ROOT/Media/TV_Shows}"
export ROOT_MUSIC="${ROOT_MUSIC:-$FUSE_ROOT/Media/Music}"
export PAPERLESS_AI_PORT="${PAPERLESS_AI_PORT:-3005}"
export IMMICH_VERSION="${IMMICH_VERSION:-release}"
export TFTP_PORT="${TFTP_PORT:-1069}"
export TIMEZONE_FILE="${TIMEZONE_FILE:-$test_root/timezone}"
export OMBI_DB_USER="${OMBI_DB_USER:-ombi}"
export OMBI_DB_PASSWORD="${OMBI_DB_PASSWORD:-ombipass}"
export OMBI_DB_ROOT_PASSWORD="${OMBI_DB_ROOT_PASSWORD:-rootpass}"
export GRAYLOG_PASSWORD_SECRET="${GRAYLOG_PASSWORD_SECRET:-supersecretstring}"
export GRAYLOG_ROOT_PASSWORD_SHA2="${GRAYLOG_ROOT_PASSWORD_SHA2:-8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918}"
export SYNC_DATA_ROOT="${SYNC_DATA_ROOT:-$data_root/syncthing/data}"

mkdir -p "$data_root" "$test_root" "$MEDIA_ROOT" "$FUSE_ROOT" "$MUM_ROOT" "$UNRAID_ROOT" \
  "$CONTAINERS_ROOT" "$NICOTINE_ROOT" "$PAPERLESS_ROOT" "$SYNC_DATA_ROOT"
mkdir -p "$(dirname "$TIMEZONE_FILE")"
if [[ ! -f "$TIMEZONE_FILE" ]]; then
  printf '%s\n' 'Australia/Perth' > "$TIMEZONE_FILE"
fi

sender_script="${UNRAID_ROOT}/appdata/inotify-bridge/sender.sh"
if [[ -d "$sender_script" ]]; then
  rm -rf "$sender_script"
fi
if [[ ! -f "$sender_script" ]]; then
  mkdir -p "$(dirname "$sender_script")"
  cat >"$sender_script" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo "sender test stub running"
while true; do
  date +%s > /tmp/sender-healthy
  sleep 30
done
SCRIPT
  chmod 755 "$sender_script"
fi

df_kb=$(df -Pk "$data_root" | awk 'NR==2 {print $4}')
if [[ -n "$df_kb" && "$df_kb" -lt 1048576 ]]; then
  podman system prune -af >/dev/null 2>&1 || true
fi

if (( prune_before )); then
  podman system prune -af >/dev/null 2>&1 || true
fi

cmd=(podman-compose -f "$compose_file_abs")
if [[ -n "${ENV_FILE:-}" ]]; then
  cmd+=("--env-file" "$ENV_FILE")
fi

podman_service_pid=""
podman_socket="${XDG_RUNTIME_DIR}/podman/podman.sock"
if [[ -d "$podman_socket" ]]; then
  rmdir "$podman_socket" 2>/dev/null || true
fi

socket_ok=0
if [[ -S "$podman_socket" ]]; then
  if python - <<'PY' >/dev/null 2>&1; then
import socket
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(1.0)
sock.connect("/run/user/%d/podman/podman.sock" % __import__("os").getuid())
sock.sendall(b"GET /_ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
sock.recv(16)
sock.close()
PY
    socket_ok=1
  fi
fi

if [[ ! -S "$podman_socket" || "$socket_ok" -ne 1 ]]; then
  mkdir -p "${XDG_RUNTIME_DIR}/podman"
  podman system service --time=0 "unix://$podman_socket" >/tmp/podman-service.log 2>&1 &
  podman_service_pid=$!
  for _ in {1..10}; do
    [[ -S "$podman_socket" ]] && break
    sleep 1
  done
fi
if [[ -S "$podman_socket" ]]; then
  chmod 666 "$podman_socket" || true
fi

cleanup() {
  "${cmd[@]}" down -v >/dev/null 2>&1 || true
  if [[ -n "${podman_service_pid}" ]]; then
    kill "${podman_service_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if (( verbose )); then
  echo "Running: DATA_ROOT=$data_root COMPOSE_PROJECT_NAME=$project_name ${cmd[*]} up -d --remove-orphans" >&2
fi

attempt=1
while true; do
  set +e
  if [[ -n "$timeout_s" ]]; then
    DATA_ROOT="$data_root" COMPOSE_PROJECT_NAME="$project_name" timeout "$timeout_s" "${cmd[@]}" up -d --remove-orphans
  else
    DATA_ROOT="$data_root" COMPOSE_PROJECT_NAME="$project_name" "${cmd[@]}" up -d --remove-orphans
  fi
  up_status=$?
  set -e
  if [[ "$up_status" -eq 0 ]]; then
    break
  fi
  if (( attempt >= retries )); then
    exit "$up_status"
  fi
  sleep_time=$((backoff_base * attempt))
  echo "Retrying in ${sleep_time}s (attempt ${attempt}/${retries})" >&2
  sleep "$sleep_time"
  attempt=$((attempt + 1))
done

sleep 5

container_ids=$("${cmd[@]}" ps -q || true)
if [[ -z "$container_ids" ]]; then
  service_names=$(awk '
    /^services:/ {in_services=1; next}
    in_services && /^[^[:space:]]/ {in_services=0}
    in_services && /^[[:space:]]{2}[^[:space:]].*:/ {
      sub(/^[[:space:]]{2}/,"");
      sub(/:.*/,"");
      print
    }
  ' "$compose_file_abs")
  for svc in $service_names; do
    ids=$(podman ps -a --filter "name=${svc}" --format '{{.ID}}' 2>/dev/null || true)
    if [[ -n "$ids" ]]; then
      container_ids="$container_ids $ids"
    fi
  done
fi
container_ids=$(echo "$container_ids" | xargs 2>/dev/null || true)
if [[ -z "$container_ids" ]]; then
  echo "No containers started for project: $project_name" >&2
  exit 1
fi

running=0
unhealthy=()
containers=()

for cid in $container_ids; do
  name=$(podman inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's#^/##')
  status=$(podman inspect "$cid" --format '{{.State.Status}}' 2>/dev/null || echo unknown)
  health=$(podman inspect "$cid" --format '{{.State.Health.Status}}' 2>/dev/null || echo none)
  containers+=("$name")
  if [[ "$status" == "running" ]]; then
    running=1
  fi
  if [[ "$health" == "unhealthy" ]]; then
    unhealthy+=("$name")
  fi
done

if (( running == 0 )); then
  echo "No containers running for project: $project_name" >&2
  for cid in $container_ids; do
    name=$(podman inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's#^/##')
    status=$(podman inspect "$cid" --format '{{.State.Status}}' 2>/dev/null || echo unknown)
    echo "--- logs: $name ($cid) status=$status ---" >&2
    podman logs "$cid" >&2 || true
  done
  exit 1
fi

if [[ ${#unhealthy[@]} -gt 0 ]]; then
  echo "Unhealthy containers: ${unhealthy[*]}" >&2
  for cid in $container_ids; do
    name=$(podman inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's#^/##')
    echo "--- logs: $name ($cid) ---" >&2
    podman logs "$cid" >&2 || true
  done
  exit 1
fi

echo "OK: $project_name (${containers[*]})"
