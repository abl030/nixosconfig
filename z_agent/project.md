# CI/CD Deployment Plan for NixOS Fleet

## Objective
To implement a secure, fast, and fully automated GitOps pipeline that updates the NixOS fleet upon a `git push` to the main branch.

## Core Components
1.  **Self-Hosted GitHub Runner:** CI jobs will execute on a trusted bastion host within our network, eliminating the need for storing SSH keys in GitHub.
2.  **Tiered Binary Caching:** A public cache (Cachix) will accelerate CI builds and a private, local cache (`nix-serve`) will provide high-speed deployments to LAN clients.
3.  **Atomic Deployments:** Configurations are built centrally and the resulting closure is pushed to target hosts for activation, ensuring reproducibility and reliability.

## Execution Plan

**Phase 1: Refactor & Simplify**
-   [ ] Integrate the Home Manager configuration directly into the NixOS modules for each host.
-   [ ] Ensure a single `nixos-rebuild switch` command updates both the system and the user environment.

**Phase 2: Secure the Foundation**
-   [ ] On the bastion host (`proxmox-vm`), deploy and configure the `services.github-runners` NixOS module.
-   [ ] Register the runner with the GitHub repository.
-   [ ] Update user permissions to allow the runner to use Nix.

**Phase 3: Accelerate the Process**
-   [ ] **Internal Cache:**
    -   [ ] Generate a signing key for `nix-serve` on the bastion host.
    -   [ ] Enable the `services.nix-serve` module.
    -   [ ] Configure Caddy as a reverse proxy for the cache endpoint (e.g., `nixcache.ablz.au`).
-   [ ] **External Cache:**
    -   [ ] Create a repository on Cachix.
    -   [ ] Add the Cachix authentication token to GitHub Secrets.
-   [ ] **All Hosts:**
    -   [ ] Update `nix.settings` on all hosts to trust and use both the internal and Cachix binary caches.

**Phase 4: Automate the Pipeline**
-   [ ] Create a final `deploy.yml` GitHub Actions workflow.
-   [ ] Configure the workflow to run on the `self-hosted` runner.
-   [ ] The workflow will check out the code, authenticate with Cachix, and execute a local deployment script that uses `nixos-rebuild --target-host` to update the fleet.
-   [ ] Remove the old SSH key secret from GitHub.

