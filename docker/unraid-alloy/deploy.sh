#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
scp "$dir/docker-compose.yml" "$dir/config.alloy" root@tower:/boot/config/alloy/
ssh root@tower "cd /boot/config/alloy && docker compose up -d"
