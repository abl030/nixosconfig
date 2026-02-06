# pfSense MCP Generator — Planning Document

## Vision

Replicate the unifi-mcp pattern for pfSense: an auto-generated MCP server with full CRUD test coverage running against a disposable pfSense VM. The entire test harness is self-contained in Nix — `nix flake check` boots a pfSense VM, runs integration tests, and tears down.

## What We Have Today

- pfSense MCP server (via `mcp-pfsense` pip package) with hand-maintained tools
- Wrapper script (`scripts/mcp-pfsense.sh`) loading sops-decrypted credentials
- Live pfSense instance with the REST API package installed (`pfrest`)
- The REST API package serves an OpenAPI spec (need to confirm endpoint)

## Phase 1: API Spec Extraction

- Pull the OpenAPI/Swagger spec from the live pfSense REST API
  - Check `https://<pfsense>/api/v2/documentation` or similar
  - The pfrest package likely serves a spec — confirm the endpoint
- Dump sample responses from each endpoint (read-only) for schema inference
- Scrub and commit to the new repo as `api-samples/` and `endpoint-inventory.json`
- Same pattern as unifi-mcp-generator

## Phase 2: Generator + Server

- Python generator reads spec + samples, outputs FastMCP server
- One tool per CRUD operation, confirmation gates on mutations
- Nix flake.nix exposing `packages.x86_64-linux.default` (like unifi-mcp)
- Integrate into nixosconfig as flake input + overlay + claude-code module package

## Phase 3: Automated Testing with pfSense VM

This is the novel part. Architecture options:

### Option A: NixOS Test Framework with Custom QEMU Node

NixOS's `nixosTest` supports custom QEMU machines. The test would:

1. Download pfSense CE ISO (or pin a specific version in the flake)
2. Boot it in QEMU with serial console, 2 NICs (WAN + LAN)
3. Script the installer via expect/serial console automation
4. Install the REST API package (`pkg install pfSense-pkg-RESTAPI`)
5. Configure admin credentials and enable the API
6. Run pytest suite against `https://<vm-ip>/api/v2/`
7. Tear down

Challenges:
- pfSense installer needs serial console scripting (expect-style)
- REST API package installation requires internet or a local pkg repo
- pfSense ISO is ~800MB — download in CI, don't commit to repo
- Boot + install + configure takes 2-3 minutes minimum

### Option B: Pre-built pfSense QCOW2 Image

1. Manually install pfSense + REST API package once
2. Snapshot the QCOW2 disk image
3. Store it as a nix derivation (fetchurl from a known location)
4. Boot from snapshot in tests — skip installation entirely
5. Much faster boot (~30s), but requires maintaining the image

### Option C: OPNsense Instead of pfSense

- OPNsense is a pfSense fork, freely redistributable
- Has its own REST API (different but similar patterns)
- Could be easier for public repo CI (no license concerns)
- But we'd be testing against a different API than production

### Recommended: Option B (Pre-built Image)

- Build the QCOW2 once, host it somewhere fetchable (GitHub release, S3, nix cache)
- Pin the image hash in the flake for reproducibility
- Tests boot in ~30s, no installer scripting needed
- Rebuild the image when upgrading pfSense versions

## Phase 4: CI Integration

- `nix flake check` runs the full test suite
- GitHub Actions with QEMU support (standard Linux runners have KVM)
- Cache the pfSense QCOW2 image to avoid re-downloading
- Same rolling update pattern as nixosconfig (daily flake.lock updates)

## Key Decisions Needed

1. **New repo or extend existing?** — Likely new repo (`abl030/pfsense-mcp`) following the unifi-mcp pattern
2. **pfSense vs OPNsense for testing?** — pfSense matches production, but OPNsense is more CI-friendly
3. **Image hosting** — Where to store the pre-built QCOW2 (GitHub Releases, nix cache, etc.)
4. **REST API package version pinning** — How to ensure test image matches production API version
5. **Spec source** — Pull from live pfSense, or from the pfrest GitHub repo's OpenAPI spec

## References

- [pfrest/pfSense-pkg-RESTAPI](https://github.com/jaredhendrickson13/pfsense-api) — The REST API package
- [pfrest.org](https://pfrest.org/) — API documentation
- [NixOS test framework](https://nixos.org/manual/nixos/stable/#sec-nixos-tests) — VM-based testing in Nix
- [unifi-mcp](https://github.com/abl030/unifi-mcp) — Reference implementation of this pattern
