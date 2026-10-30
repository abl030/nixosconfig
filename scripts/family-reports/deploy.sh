#!/usr/bin/env bash
# Deploy the family-reports Email Worker (worker.js) to Cloudflare, creating
# its KV namespaces if needed. Idempotent. Needs a curl header file holding
# `Authorization: Bearer <token>` for a token with Workers Scripts Write and
# Workers KV Storage Write on the account (mint a short-lived one; none is
# kept in the repo). See docs/wiki/services/family-public-site.md.
#
#   scripts/family-reports/deploy.sh /run/user/1000/cf/setup.h
set -euo pipefail
auth=${1:?usage: deploy.sh AUTH_HEADER_FILE}
here=$(cd "$(dirname "$0")" && pwd)
acct=50e4b91849779897b003ddaddf5d10eb
api=https://api.cloudflare.com/client/v4/accounts/$acct
approved_to=abl030+familyreports@gmail.com
staging_to=abl030+familystaging@gmail.com

cf() { curl -fsS -H @"$auth" "$@"; }

namespace() {
  local title=$1 id
  id=$(cf "$api/storage/kv/namespaces?per_page=100" | jq -r --arg t "$title" '.result[] | select(.title == $t) | .id')
  if [[ -z "$id" ]]; then
    id=$(cf -H 'Content-Type: application/json' -X POST --data "$(jq -n --arg t "$title" '{title: $t}')" \
      "$api/storage/kv/namespaces" | jq -r .result.id)
  fi
  echo "$id"
}

approved=$(namespace family-reports-approved)
replies=$(namespace family-reports-replies)
echo "kv: approved=$approved replies=$replies"

meta=$(jq -n --arg a "$approved" --arg r "$replies" --arg at "$approved_to" --arg st "$staging_to" '{
  main_module: "worker.js",
  compatibility_date: "2026-09-01",
  bindings: [
    {type: "kv_namespace", name: "APPROVED", namespace_id: $a},
    {type: "kv_namespace", name: "REPLIES", namespace_id: $r},
    {type: "plain_text", name: "APPROVED_TO", text: $at},
    {type: "plain_text", name: "STAGING_TO", text: $st}
  ]}')
cf -X PUT "$api/workers/scripts/family-reports" \
  -F "metadata=$meta;type=application/json" \
  -F "worker.js=@$here/worker.js;type=application/javascript+module" |
  jq -c '{success, id: .result.id, modified: .result.modified_on}'
