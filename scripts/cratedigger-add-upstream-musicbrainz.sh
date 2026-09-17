#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo "usage: $0 <musicbrainz-release-mbid>" >&2
  exit 2
fi

mbid=$1
if [[ ! $mbid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "invalid MusicBrainz release MBID: $mbid" >&2
  exit 2
fi

pipeline_cli=$(readlink -f "$(command -v pipeline-cli)")
runtime_config=$(
  sed -n 's/^export CRATEDIGGER_RUNTIME_CONFIG="\([^"]*\)"$/\1/p' \
    "$pipeline_cli"
)
if [[ -z $runtime_config || ! -f $runtime_config ]]; then
  echo "could not resolve pipeline-cli runtime config" >&2
  exit 3
fi

workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT
cp -- "$runtime_config" "$workdir/config.ini"
sed -i \
  '/^\[MusicBrainz\]/,/^\[/ s|^api_base = .*|api_base = https://musicbrainz.org|' \
  "$workdir/config.ini"
sed \
  "s|^export CRATEDIGGER_RUNTIME_CONFIG=.*|export CRATEDIGGER_RUNTIME_CONFIG=\"$workdir/config.ini\"|" \
  "$pipeline_cli" > "$workdir/pipeline-cli"
chmod 0700 "$workdir/pipeline-cli"

"$workdir/pipeline-cli" add "$mbid"
