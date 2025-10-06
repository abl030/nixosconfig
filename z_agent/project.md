Of course. Consolidating state into a single, declarative module is an excellent final step for maintainability.

Here is the updated `project.md` with the new Phase 5.

===== ./z_agent/project.md =====
# CI/CD Deployment Plan for NixOS Fleet

## Objective
To implement a secure, fast, and fully automated GitOps pipeline that updates the NixOS fleet upon a `git push` to the main branch.

## Core Components
1.  **Self-Hosted GitHub Runner:** CI jobs will execute on a trusted bastion host within our network, eliminating the need for storing SSH keys in GitHub.
2.  **Tiered Binary Caching:** A public cache (Cachix) will accelerate CI builds, a private `nix-serve` cache will provide high-speed deployments for local builds, and a local Nginx mirror will cache public artifacts.
3.  **Atomic Deployments:** Configurations are built centrally and the resulting closure is pushed to target hosts for activation, ensuring reproducibility and reliability.

## Execution Plan

**Phase 1: Refactor & Simplify**
-   [*] Integrate the Home Manager configuration directly into the NixOS modules for each host.
-   [*] Ensure a single `nixos-rebuild switch` command updates both the system and the user environment.

**Phase 2: Secure the Foundation**
-   [*] On the bastion host (`proxmox-vm`), deploy and configure the `services.github-runners` NixOS module.
-   [*] Register the runner with the GitHub repository.
-   [*] Update user permissions to allow the runner to use Nix.

**Phase 3: Accelerate the Process**
-   [*] **Internal Cache (Push Cache):**
    -   [*] Generate a signing key for `nix-serve` on the bastion host.
    -   [*] Enable the `services.nix-serve` module.
    -   [*] Configure Caddy as a reverse proxy for the cache endpoint (e.g., `nixcache.ablz.au`).
-   [ ] **Local Upstream Mirror (Pull-Through Cache):**
    -   [ ] On the bastion host, enable the `services.nginx` module to run natively.
    -   [ ] Create persistent storage directories for the Nginx cache (e.g., under `/var/cache/nginx-nix-proxy`) and ensure the `nginx` user has write permissions.
    -   [ ] Define a new Nginx virtual host (e.g., `nix-mirror.ablz.au`) configured as a transparent caching proxy for `cache.nixos.org`.
    -   [ ] Configure TLS for the new endpoint, either directly in Nginx or via Caddy.
-   [ ] **External Cache:**
    -   [ ] Create a repository on Cachix.
    -   [ ] Add the Cachix authentication token to GitHub Secrets.
-   [ ] **All Hosts:**
    -   [ ] Update `nix.settings` on all hosts to trust and use the full tiered cache hierarchy: first the internal `nix-serve` cache, then the local Nginx mirror, then Cachix, and finally the public cache.

**Phase 4: Automate the Pipeline**
-   [ ] Create a final `deploy.yml` GitHub Actions workflow.
-   [ ] Configure the workflow to run on the `self-hosted` runner.
-   [ ] The workflow will check out the code, authenticate with Cachix, and execute a local deployment script that uses `nixos-rebuild --target-host` to update the fleet.
-   [ ] Remove the old SSH key secret from GitHub.

**Phase 5: Modularize and Harden Caching Services**
-   **Objective:** Refactor the push cache (`nix-serve`) and its reverse proxy into a single, declarative, and secure NixOS module. This will consolidate configuration from three separate places (host config, Docker Compose, Caddyfile) into one file.
-   [ ] **Create a Reusable NixOS Module:**
    -   [ ] Develop a new module (e.g., `modules/nixos/private-nix-cache.nix`).
    -   [ ] Define high-level options like `enable`, `hostName`, `secretKeyPath`, and `apiTokenPath`.
-   [ ] **Consolidate Services:**
    -   [ ] The module will internally configure `services.nix-serve`, binding it securely to localhost.
    -   [ ] The module will also configure the native `services.caddy` NixOS module to act as a reverse proxy.
    -   [ ] The native Caddy instance will be configured for automatic TLS certificate acquisition using a DNS challenge.
-   [ ] **Integrate Declarative Secrets:**
    -   [ ] Utilize `sops-nix` to manage all secrets for the module.
    -   [ ] Encrypt the `nix-serve` private signing key and the DNS provider API token.
    -   [ ] The new module will read these secrets from their decrypted paths (e.g., `/run/secrets/nix-serve-key`).
-   [ ] **Finalize Implementation:**
    -   [ ] Remove the old, scattered `nix-serve` configuration from the bastion host.
    -   [ ] Remove the Caddy Docker container service from the stack.
    -   [ ] Enable the new, consolidated module on the bastion host with just a few lines of configuration.
