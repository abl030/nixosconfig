#!/usr/bin/env bash
set -Eeuo pipefail

# Update the official MongoDB Community 8.0 Ubuntu 24.04 binary used by UniFi.
# This script is called as the `mongodb80` transaction in
# scripts/rolling_flake_update.sh. It must fail before editing the package when
# release discovery, archive verification, or hash prefetch fails.

PACKAGE_FILE="${MONGODB80_PACKAGE_FILE:-nix/pkgs/mongodb80.nix}"
RELEASES_URL="https://downloads.mongodb.org/current.json"
SERIES="8.0"
ARCHIVE_PREFIX="mongodb-linux-x86_64-ubuntu2404"

fail() {
  printf 'mongodb80-update: %s\n' "$*" >&2
  exit 1
}

[ -f "$PACKAGE_FILE" ] || fail "package file does not exist: $PACKAGE_FILE"

version_count="$(grep -Ec '^[[:space:]]*version = "[0-9]+\.[0-9]+\.[0-9]+";' "$PACKAGE_FILE" || true)"
[ "$version_count" -eq 1 ] || fail "expected exactly one package version assignment in $PACKAGE_FILE"

current_version="$(sed -nE 's/^[[:space:]]*version = "([0-9]+\.[0-9]+\.[0-9]+)";/\1/p' "$PACKAGE_FILE")"
case "$current_version" in
  "$SERIES".*) ;;
  *) fail "package is outside the protected $SERIES series: $current_version" ;;
esac

release_feed="$(mktemp)"
checksum_file="$(mktemp)"
prefetch_json="$(mktemp)"
tar_listing="$(mktemp)"
updated_package="$(mktemp "${PACKAGE_FILE}.XXXXXX")"
cleanup() {
  rm -f "$release_feed" "$checksum_file" "$prefetch_json" "$tar_listing" "$updated_package"
}
trap cleanup EXIT

# MongoDB's official current-release feed is the release authority. Select only
# stable Community builds for the exact platform this package consumes. Do not
# discover a version from an arbitrary mirror or from a major/minor-unbounded
# "latest" endpoint.
curl --fail --silent --show-error --location --retry 3 --max-time 30 \
  "$RELEASES_URL" --output "$release_feed" \
  || fail "could not read the official Community release feed"

latest_record="$(
jq -er --arg series "$SERIES" '
  .versions[]
  | select(.version | startswith($series + "."))
  | select(.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
  | select(.release_candidate == false and .production_release == true)
  | .version as $version
  | .downloads[]
  | select(.edition == "targeted" and .target == "ubuntu2404" and .arch == "x86_64")
  | [$version, .archive.url]
  | @tsv
' "$release_feed" \
  | sort -Vu \
  | sed -n '$p' \
  || true
)"
[ -n "$latest_record" ] || fail "the official release feed contained no stable $SERIES Community build for Ubuntu 24.04 x64"
IFS=$'\t' read -r latest_version archive_url extra <<< "$latest_record"
[ -n "$latest_version" ] && [ -n "$archive_url" ] && [ -z "${extra:-}" ] \
  || fail "the official release feed returned a malformed $SERIES Community record"

case "$latest_version" in
  "$SERIES".*) ;;
  *) fail "release discovery crossed the protected $SERIES boundary: $latest_version" ;;
esac

if [ "$latest_version" = "$current_version" ]; then
  printf 'mongodb80-update: already at official %s\n' "$current_version"
  exit 0
fi

oldest="$(printf '%s\n' "$current_version" "$latest_version" | sort -V | sed -n '1p')"
[ "$oldest" = "$current_version" ] || fail "refusing a downgrade from $current_version to $latest_version"

expected_archive_url="https://fastdl.mongodb.org/linux/${ARCHIVE_PREFIX}-${latest_version}.tgz"
[ "$archive_url" = "$expected_archive_url" ] \
  || fail "official $latest_version Community archive URL does not match the protected Ubuntu 24.04 x64 package"
archive_name="${ARCHIVE_PREFIX}-${latest_version}.tgz"

# MongoDB publishes a checksum beside every archive. Fetch that exact official
# checksum first and require the downloaded bytes to match it. Both are trusted
# via MongoDB HTTPS; this detects corruption/mismatches, not a compromised
# vendor origin. Nix then pins the verified bytes for reproducible deployment.
curl --fail --silent --show-error --location --retry 3 --max-time 30 \
  "${archive_url}.sha256" --output "$checksum_file" \
  || fail "could not read the official SHA-256 checksum for $archive_name"

official_hex=""
official_matches=0
while read -r checksum filename extra; do
  filename="${filename#\*}"
  if [ "$filename" = "$archive_name" ] && [ -z "$extra" ]; then
    official_hex="$checksum"
    official_matches=$((official_matches + 1))
  fi
done < "$checksum_file"
[ "$official_matches" -eq 1 ] \
  || fail "official checksum file did not contain exactly one entry for $archive_name"
[[ "$official_hex" =~ ^[[:xdigit:]]{64}$ ]] \
  || fail "official checksum for $archive_name is not a SHA-256 value"
official_hash="$(nix hash convert --hash-algo sha256 --to sri "$official_hex")" \
  || fail "could not convert the official checksum to Nix SRI"

# Prefetch through Nix so the exact archive used by fetchurl is retained in the
# Nix store for the tar-layout check. The calculated hash is accepted only after
# it matches the independently fetched official checksum above.
nix store prefetch-file --json --no-pretty --hash-type sha256 \
  --name "$archive_name" "$archive_url" > "$prefetch_json" \
  || fail "Nix could not prefetch $archive_url"

archive_hash="$(jq -er '.hash | select(type == "string" and startswith("sha256-"))' "$prefetch_json")" \
  || fail "Nix prefetch did not return a SHA-256 SRI hash"
archive_store_path="$(jq -er '.storePath | select(type == "string" and startswith("/nix/store/"))' "$prefetch_json")" \
  || fail "Nix prefetch did not return an archive store path"
[ -f "$archive_store_path" ] || fail "prefetched archive is not a regular file: $archive_store_path"
[ "$archive_hash" = "$official_hash" ] \
  || fail "downloaded archive hash $archive_hash does not match official checksum $official_hash"

# Check the archive's expected official layout before changing source. This
# rejects an HTML/error payload that happened to receive a successful HTTP
# response and proves both server binaries are present.
tar -tzf "$archive_store_path" > "$tar_listing" \
  || fail "official archive is not a readable gzip tarball"
for binary in mongod mongos; do
  grep -Fx "${ARCHIVE_PREFIX}-${latest_version}/bin/$binary" "$tar_listing" >/dev/null \
    || fail "official archive is missing bin/$binary"
done

hash_count="$(grep -Ec '^[[:space:]]*hash = "sha256-[^"]+";' "$PACKAGE_FILE" || true)"
source_hash_count="$(grep -Ec '^[[:space:]]*sourceHash = "sha256-[^"]+";' "$PACKAGE_FILE" || true)"
[ "$hash_count" -eq 1 ] || fail "expected exactly one fetchurl hash assignment in $PACKAGE_FILE"
[ "$source_hash_count" -eq 1 ] || fail "expected exactly one sourceHash assignment in $PACKAGE_FILE"

# Replace only the one version and the two intentionally duplicated hash
# records (fetchurl + provenance passthru). The archive has already been
# verified, so a failed write cannot leave a half-updated file.
sed \
  -e "s#^\([[:space:]]*version = \"\)[0-9]\+\.[0-9]\+\.[0-9]\+\(\";\)#\1${latest_version}\2#" \
  -e "s#^\([[:space:]]*hash = \"\)sha256-[^\"]\+\(\";\)#\1${archive_hash}\2#" \
  -e "s#^\([[:space:]]*sourceHash = \"\)sha256-[^\"]\+\(\";\)#\1${archive_hash}\2#" \
  "$PACKAGE_FILE" > "$updated_package"

cmp -s "$PACKAGE_FILE" "$updated_package" && fail "candidate $latest_version produced no package-file change"
chmod --reference="$PACKAGE_FILE" "$updated_package"
mv "$updated_package" "$PACKAGE_FILE"
printf 'mongodb80-update: advanced official %s -> %s (%s)\n' \
  "$current_version" "$latest_version" "$archive_hash"
