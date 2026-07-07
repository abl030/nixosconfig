#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  moonlight-iperf.sh --client <ssh-host> [options]

Options:
  --client HOST          SSH host/alias for the client to test.
  --server-ip IP        Wired server LAN IP. Default: 192.168.1.29.
  --client-ip IP        Client LAN IP. Default: discover over SSH.
  --port PORT           iperf TCP/UDP control port. Default: 5201.
  --duration SECONDS    TCP test duration. Default: 20.
  --udp-duration SEC    UDP test duration. Default: 30.
  --udp-rates LIST      Comma-separated UDP rates. Default: 30M,60M,120M.
  --udp-len BYTES       UDP payload length. Default: 1200.
  --udp-window SIZE     UDP socket buffer/window. Default: 4M.
  --udp-omit SECONDS    UDP warm-up seconds to omit. Default: 3.
  --parallel N          Parallel TCP downlink streams. Default: 4.
  --remote-server       Run iperf server on the client and connect from here.
  --no-firewall         Do not add temporary local NixOS firewall rules.
  --no-wakelock         Do not call termux-wake-lock/unlock on client.
  -h, --help            Show this help.

Examples:
  moonlight-iperf.sh --client fra
  moonlight-iperf.sh --client phone --remote-server
  moonlight-iperf.sh --client phone --server-ip 192.168.1.29 --udp-rates 20M,40M,60M
EOF
}

client=""
server_ip="192.168.1.29"
client_ip=""
port="5201"
duration="20"
udp_duration="30"
udp_rates="30M,60M,120M"
udp_len="1200"
udp_window="4M"
udp_omit="3"
parallel="4"
remote_server=0
manage_firewall=1
wakelock=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client) client="${2:-}"; shift 2 ;;
    --server-ip) server_ip="${2:-}"; shift 2 ;;
    --client-ip) client_ip="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --duration) duration="${2:-}"; shift 2 ;;
    --udp-duration) udp_duration="${2:-}"; shift 2 ;;
    --udp-rates) udp_rates="${2:-}"; shift 2 ;;
    --udp-len) udp_len="${2:-}"; shift 2 ;;
    --udp-window) udp_window="${2:-}"; shift 2 ;;
    --udp-omit) udp_omit="${2:-}"; shift 2 ;;
    --parallel) parallel="${2:-}"; shift 2 ;;
    --remote-server) remote_server=1; shift ;;
    --no-firewall) manage_firewall=0; shift ;;
    --no-wakelock) wakelock=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$client" ]]; then
  echo "--client is required" >&2
  usage >&2
  exit 2
fi

have() { command -v "$1" >/dev/null 2>&1; }

nix_bin() {
  local attr="$1" bin="$2"
  if have "$bin"; then
    command -v "$bin"
    return
  fi
  if have nix; then
    nix build --no-link --print-out-paths "nixpkgs#${attr}.out" 2>/dev/null | tail -1 | sed "s,$,/bin/${bin},"
    return
  fi
  echo "$bin"
}

local_iperf() {
  if have iperf3; then
    iperf3 "$@"
  else
    nix shell nixpkgs#iperf -c iperf3 "$@"
  fi
}

remote_iperf_prefix='if command -v iperf3 >/dev/null 2>&1; then iperf3 "$@"; elif command -v iperf >/dev/null 2>&1; then iperf "$@"; elif command -v nix >/dev/null 2>&1; then nix shell nixpkgs#iperf -c iperf3 "$@"; else echo "iperf3 not found on client" >&2; exit 127; fi'

remote_iperf() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$client" "bash -lc 'f(){ ${remote_iperf_prefix}; }; f \"\$@\"' -- $*"
}

remote_sh() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$client" "$@"
}

discover_client_ip() {
  local found="" server_prefix
  server_prefix="${server_ip%.*}."

  found="$(
    remote_sh "{
      ip route get ${server_ip} 2>/dev/null
      ip -4 addr show wlan0 2>/dev/null
      ifconfig wlan0 2>/dev/null
      ip -4 addr show 2>/dev/null
      ifconfig 2>/dev/null
    } | sed -n \
      -e 's/.* src \\([0-9.][0-9.]*\\).*/\\1/p' \
      -e 's/.*inet \\([0-9.][0-9.]*\\)\\/.*/\\1/p' \
      -e 's/.*inet addr:\\([0-9.][0-9.]*\\).*/\\1/p' \
      -e 's/.*inet \\([0-9.][0-9.]*\\) .*/\\1/p'" \
      2>/dev/null \
      | awk '!seen[$0]++'
  )"

  printf '%s\n' "$found" | grep -m1 -F "$server_prefix" \
    || printf '%s\n' "$found" | grep -m1 -Ev '^(127\.|100\.|169\.254\.)' \
    || true
}

iptables_bin=""
cleanup_rules=()
server_pid=""

cleanup() {
  set +e
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  if [[ "$remote_server" -eq 1 ]]; then
    remote_sh "pkill iperf3 2>/dev/null || true" >/dev/null 2>&1 || true
  fi
  if [[ ${#cleanup_rules[@]} -gt 0 && -n "$iptables_bin" ]]; then
    for rule in "${cleanup_rules[@]}"; do
      # shellcheck disable=SC2086
      sudo -n "$iptables_bin" -D nixos-fw $rule >/dev/null 2>&1 || true
    done
  fi
  if [[ "$wakelock" -eq 1 ]]; then
    remote_sh "command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock || true" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

if [[ -z "$client_ip" ]]; then
  client_ip="$(discover_client_ip || true)"
fi

if [[ -z "$client_ip" ]]; then
  echo "could not discover client IP; pass --client-ip" >&2
  exit 1
fi

echo "Moonlight iperf"
echo "  client ssh:  $client"
echo "  client ip:   $client_ip"
echo "  server ip:   $server_ip"
echo "  mode:        $([[ "$remote_server" -eq 1 ]] && echo remote-server || echo local-server)"
echo

if [[ "$wakelock" -eq 1 ]]; then
  remote_sh "command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock || true" >/dev/null 2>&1 || true
fi

add_fw_rule() {
  local spec="$1"
  if [[ "$manage_firewall" -ne 1 ]]; then
    return
  fi
  if [[ -z "$iptables_bin" ]]; then
    iptables_bin="$(nix_bin iptables iptables)"
  fi
  if sudo -n "$iptables_bin" -S nixos-fw >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    sudo -n "$iptables_bin" -I nixos-fw 3 $spec
    cleanup_rules+=("$spec")
  fi
}

run_section() {
  echo
  echo "== $* =="
}

if [[ "$remote_server" -eq 0 ]]; then
  add_fw_rule "-s ${client_ip}/32 -p tcp --dport ${port} -j nixos-fw-accept"
  add_fw_rule "-s ${client_ip}/32 -p udp --dport ${port} -j nixos-fw-accept"

  local_iperf -s -B "$server_ip" -p "$port" &
  server_pid="$!"
  sleep 1

  run_section "TCP uplink: client -> server"
  remote_iperf -4 -c "$server_ip" -p "$port" -i 1 -t "$duration" || true

  run_section "TCP downlink: server -> client (-R)"
  remote_iperf -4 -c "$server_ip" -p "$port" -R -i 1 -t "$duration" || true

  run_section "TCP downlink ceiling: server -> client (-R -P ${parallel})"
  remote_iperf -4 -c "$server_ip" -p "$port" -R -P "$parallel" -i 1 -t "$duration" || true

  IFS=',' read -r -a rates <<< "$udp_rates"
  for rate in "${rates[@]}"; do
    run_section "UDP downlink: server -> client (-u -R -b ${rate})"
    remote_iperf -4 -c "$server_ip" -p "$port" -u -R -b "$rate" -l "$udp_len" -w "$udp_window" -O "$udp_omit" -i 1 --get-server-output -t "$udp_duration" || true
  done
else
  remote_sh "pkill iperf3 2>/dev/null || true; iperf3 -s -B ${client_ip} -p ${port}" &
  server_pid="$!"
  sleep 2

  run_section "TCP downlink: server -> client"
  local_iperf -4 -c "$client_ip" -p "$port" -i 1 -t "$duration" || true

  run_section "TCP uplink: client -> server (-R)"
  local_iperf -4 -c "$client_ip" -p "$port" -R -i 1 -t "$duration" || true

  run_section "TCP downlink ceiling: server -> client (-P ${parallel})"
  local_iperf -4 -c "$client_ip" -p "$port" -P "$parallel" -i 1 -t "$duration" || true

  IFS=',' read -r -a rates <<< "$udp_rates"
  for rate in "${rates[@]}"; do
    run_section "UDP downlink attempt: server -> client (-u -b ${rate})"
    local_iperf -4 -c "$client_ip" -p "$port" -u -b "$rate" -l "$udp_len" -w "$udp_window" -O "$udp_omit" -i 1 --get-server-output -t "$udp_duration" || true
  done
fi

cat <<'EOF'

Interpretation:
  - For Moonlight, prefer the highest clean UDP downlink rate.
  - If UDP downlink is clean, start Moonlight at ~70% of that rate.
  - If UDP is inconclusive, use 40-60% of single-stream TCP downlink as a provisional cap.
  - If single-stream TCP is weak but multi-stream TCP is strong, choose conservatively and verify with a real Moonlight soak.
EOF
