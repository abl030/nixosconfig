#!/usr/bin/env bash
set -Eeuo pipefail

# Bump whatsapp-archive's Go dependencies (whatsmeow above all) to latest and
# refresh vendorHash. Called as the `whatsapp-archive` transaction in
# scripts/rolling_flake_update.sh, which builds every host before committing
# and reverts on failure. WhatsApp logs out clients whose protocol version
# falls behind, so these deps deliberately float instead of staying pinned.
# Runnable by hand from the repo root, too.
# See docs/wiki/services/whatsapp-archive.md.

PKG_DIR="nix/pkgs/whatsapp-archive"
PACKAGE_FILE="$PKG_DIR/package.nix"

fail() {
  printf 'whatsapp-archive-update: %s\n' "$*" >&2
  exit 1
}

[ -f "$PACKAGE_FILE" ] || fail "run from the repo root ($PACKAGE_FILE missing)"
[ "$(grep -c 'vendorHash = "sha256-' "$PACKAGE_FILE")" -eq 1 ] \
  || fail "expected exactly one vendorHash in $PACKAGE_FILE"

work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
export GOPATH="$work/gopath" GOCACHE="$work/gocache" GOFLAGS=-modcacherw CGO_ENABLED=0 GOTOOLCHAIN=local

# The flake's own Go, so go.mod's `go` line never outruns the build toolchain.
gorun() {
  (cd "$PKG_DIR" && nix shell --inputs-from . nixpkgs#go -c go "$@")
}
gorun get -u ./... || fail "go get -u failed"
gorun mod tidy || fail "go mod tidy failed"
gorun vet ./... || fail "go vet failed after the bump"

if git diff --quiet -- "$PKG_DIR/go.mod" "$PKG_DIR/go.sum"; then
  echo "whatsapp-archive-update: already current"
  exit 0
fi

# Rebuild the vendor FOD with a fake hash and take the real one from the error.
fake="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
sed -i -E "s|vendorHash = \"sha256-[^\"]+\";|vendorHash = \"$fake\";|" "$PACKAGE_FILE"
expr='let pkgs = (builtins.getFlake (toString ./.)).nixosConfigurations.doc2.pkgs;
      in (import ./nix/pkgs/whatsapp-archive/package.nix {inherit pkgs;}).goModules'
out="$(nix build --no-link --impure --expr "$expr" 2>&1 || true)"
hash="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*got:[[:space:]]*(sha256-[A-Za-z0-9+/=]+)$/\1/p' | tail -n1)"
if [ -z "$hash" ]; then
  git checkout -- "$PACKAGE_FILE"
  printf '%s\n' "$out" | tail -20 >&2
  fail "could not determine the new vendorHash"
fi
sed -i -E "s|vendorHash = \"$fake\";|vendorHash = \"$hash\";|" "$PACKAGE_FILE"

whatsmeow="$(sed -nE 's/^[[:space:]]*go\.mau\.fi\/whatsmeow (v[^ ]+).*/\1/p' "$PKG_DIR/go.mod")"
echo "whatsapp-archive-update: whatsmeow $whatsmeow, vendorHash $hash"
