# Tailscale Auth Automation

## Overview

Automate Tailscale enrollment during post-provision using OAuth client credentials to mint short-lived, single-use auth keys on demand.

## Architecture

```
SOPS-encrypted OAuth credentials (secrets/secrets/tailscale-oauth.yaml)
         │
         ▼
   post-provision.sh decrypts via sops
         │
         ▼
   Calls Tailscale API to mint a
   short-lived (10min), single-use key
         │
         ▼
   SSH to VM (TTY): sudo tailscale up --authkey <key>
   (passwordless sudo for tailscale in base.nix is optional)
         │
         ▼
   Key consumed immediately, VM joins tailnet
```

## Components

### 1. OAuth Client (Tailscale Admin Console)

Create an OAuth client at https://login.tailscale.com/admin/settings/oauth:
- Scope: `auth_keys` (write)
- Tags: Select which tags the client can assign (e.g., `tag:server`)

The OAuth client can mint auth keys but only for devices with the specified tags.

### 2. SOPS Secret (`secrets/secrets/tailscale-oauth.yaml`)

Store the OAuth credentials encrypted:

```yaml
oauth_client_id: "k..."
oauth_client_secret: "tskey-client-..."
tailnet: "your-tailnet.ts.net"
tags:
  - "tag:server"
expiry_seconds: 600
```

### 3. Sudo for Tailscale (`base.nix`)

Fleet machines allow passwordless sudo for the tailscale binary (optional):

```nix
security.sudo.extraRules = [{
  users = [hostConfig.user];
  commands = [{
    command = "${pkgs.tailscale}/bin/tailscale";
    options = ["NOPASSWD"];
  }];
}];
```

Post-provision will request sudo via SSH with a TTY, so interactive runs work
even if passwordless sudo is not desired.

### 4. Post-Provision Integration (`vms/post-provision.sh`)

The script already has the integration:
- `tailscale_load_oauth_creds()` - loads from env or SOPS file
- `tailscale_create_auth_key()` - mints key via Tailscale API
- `tailscale_join_vm()` - SSHes to VM and runs `tailscale up`

## Usage

Tailscale enrollment is **enabled by default**. Just run:

```bash
nix run .#post-provision-vm <vm-name> <vmid>
```

The script automatically looks for credentials at `secrets/secrets/tailscale-oauth.yaml`.

To **disable** Tailscale enrollment:

```bash
POST_PROVISION_TAILSCALE=0 nix run .#post-provision-vm <vm-name> <vmid>
```

To use a custom credentials file or environment variables:

```bash
# Custom SOPS file location
export POST_PROVISION_TAILSCALE_SOPS_FILE="/path/to/tailscale-oauth.yaml"

# Or set credentials directly (for testing)
export TAILSCALE_OAUTH_CLIENT_ID="k..."
export TAILSCALE_OAUTH_CLIENT_SECRET="tskey-client-..."
export TAILSCALE_TAILNET="your-tailnet.ts.net"
export TAILSCALE_TAGS="tag:server"
```

## Security Model

| Component | Storage | Scope | Lifetime |
|-----------|---------|-------|----------|
| OAuth client secret | SOPS-encrypted | Can only create tagged devices | Long-lived |
| Machine auth key | Memory only | Single device | 10 minutes, single-use |

The OAuth secret is the sensitive credential. Auth keys minted from it are:
- Short-lived (600 seconds default)
- Single-use (`reusable: false`)
- Ephemeral (`ephemeral: true`)
- Pre-authorized (`preauthorized: true`)

## Setup Checklist

- [x] Passwordless sudo for tailscale in `base.nix`
- [x] Create OAuth client in Tailscale admin console
- [x] Create `secrets/secrets/tailscale-oauth.yaml` with credentials
- [x] Test with `POST_PROVISION_TAILSCALE=1`
