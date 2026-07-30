# Immich

**Module:** `modules/nixos/services/immich.nix`
**URL:** `https://photos.ablz.au`
**Incidents:** [asset-edit audit](immich-asset-edit-audit-incident.md),
[DB function ownership](immich-db-function-ownership-incident.md)

## Sending a photo to the agent

This is the practical reason the API key exists, and it is genuinely useful:
**it is how the operator shows the agent something physical.** Take a photo on the
phone (it auto-uploads), open it in Immich, paste the URL into the session. The
agent pulls the asset over the API and looks at it directly.

Established 2026-07-30 while fixing an RDP prompt on a POS terminal — a phone
photo of the on-screen dialog settled in one round-trip what several rounds of
"what exactly does it say?" had not.

Good for: an error dialog on a screen the agent cannot reach, a cable run or port
layout, a serial/model number, a blinking status LED, anything on a device with no
management interface.

### How to do it

The web URL is `https://photos.ablz.au/photos/<assetId>`. That page is the SPA
shell — fetching it returns HTML, not the image. Use the API with the key:

```bash
TOKEN=$(env -C "$PWD/secrets" sops -d --extract '["token"]' \
          hosts/proxmox-vm/immich-api-token.yaml)          # or /run/secrets/immich/api-token

ASSET=addcaaf5-832d-45ae-bd92-b67f58b81cdf                 # the id from the URL

# preview is the right size for reading a screen; use /original for fine detail
curl -sS -H "x-api-key: $TOKEN" \
  "https://photos.ablz.au/api/assets/$ASSET/thumbnail?size=preview" -o /tmp/shot.jpg
```

Then read `/tmp/shot.jpg` with the Read tool, which renders it.

Useful endpoints:

| Endpoint | Use |
|---|---|
| `GET /api/assets/<id>/thumbnail?size=preview` | Fast, ~400 KB, enough to read a screen |
| `GET /api/assets/<id>/original` | Full resolution, for small text or fine detail |
| `GET /api/assets/<id>` | Metadata: timestamp, device, EXIF |
| `POST /api/search/metadata` | Find assets without a URL |

The asset id is the UUID in the web URL — no separate lookup needed.

## The API key

Stored sops-encrypted, **doc1-scope only**, at
`secrets/hosts/proxmox-vm/immich-api-token.yaml`, materialised on doc1 at
`/run/secrets/immich/api-token` (owner `abl030`, mode `0400`). Wired in
`hosts/proxmox-vm/configuration.nix`.

**Scope warning.** Immich API keys carry the full privileges of the owning user —
there is no read-only or scoped key. This one can read, modify and delete the
entire photo library. Treat it as a control-plane credential: doc1 only, alongside
the pfSense/UniFi/HA/Forgejo keys, never fleet-wide and never on a sibling. See
`modules/nixos/services/tailscale/acl-apply.nix` for the same reasoning applied to
the Tailscale credential.

**Rotate** in the Immich web UI (Account Settings → API Keys): create the new key,
re-encrypt the sops file, deploy doc1, delete the old key.

Note that the key was originally pasted into a chat session in plaintext, so it
exists in that transcript. Rotate if that transcript's retention is ever a concern.

## Probes

`modules/nixos/services/probes/check-immich-sync.nix` deliberately checks Immich
at the **database** level (`SELECT 1 FROM asset_edit_audit`) rather than over HTTP.
Immich rejects API-key auth on the sync endpoints
(`"Sync endpoints cannot be used with API keys"`), and a SQL probe needs no key,
survives endpoint renames, and tests the exact permission state from the original
incident. See [the incident writeup](immich-asset-edit-audit-incident.md).
