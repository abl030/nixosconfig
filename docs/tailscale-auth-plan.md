# Tailscale Auth Automation Plan

## Goal
Automate Tailscale enrollment during post-provision without storing a reusable auth key.
Use a trusted, already-enrolled machine to mint short-lived, single-use keys via the API.

## Assumptions
- Post-provision runs on a machine already in the tailnet.
- Tailscale OAuth client credentials are stored in SOPS on the provisioning machine.
- New VM can be reached by IP during the run (SSH alias may not exist yet).

## Workflow
1) Add Tailscale OAuth client creds to `secrets/` (SOPS-encrypted) and wire into post-provision.
2) In `post-provision.sh`, add a `POST_PROVISION_TAILSCALE=1` path:
   - Create a short-lived, non-reusable auth key via API (optionally tagged).
   - SSH to the VM by IP and run `tailscale up --authkey <key>`.
   - Validate `tailscale status` and/or expected hostname.
   - Revoke the key if API supports immediate revocation.
3) Add logging + error handling; keep it opt-in.

## Test Flow (using test VM)
Only Step 2 needs manual validation; all other steps are handled by post-provision.

Step 2) Join Tailscale on the VM (manual for now):
- `ssh abl030@<ip> "sudo tailscale up --authkey <one-time-key>"`

## Exit Criteria
- New VM joins tailnet using a short-lived single-use key minted at runtime.
- Post-provision succeeds using VM IP only (tailscale join still manual for now).
- No long-lived auth key stored in plaintext outside SOPS.
