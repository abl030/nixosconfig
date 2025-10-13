# NixOS Configuration Repository

A comprehensive, flake-based NixOS configuration repository managing multiple hosts with automated builds, declarative infrastructure, and reproducible environments.

## 1. Project Overview

**Purpose:** This repository provides declarative NixOS system configurations for multiple hosts, including desktop workstations, servers, and container hosts. It automates nightly builds, maintains consistent environments across machines, and publishes artifacts to a binary cache for fast deployments.

**Key Features:**

- 🔄 **Deterministic builds** using Nix flakes
- 🏠 **Home Manager integration** for user-level configurations
- 🐳 **Docker Compose services** managed declaratively via Nix
- 📦 **Automated binary caching** via Cachix and self-hosted cache
- 🤖 **CI/CD automation** with GitHub Actions
- 🔐 **Secrets management** using sops-nix
- 🎯 **Multiple host types**: Framework laptop, Proxmox VMs, WSL, GPU passthrough hosts

**Managed Hosts:**

- `framework` - Framework 13 AMD laptop (primary workstation)
- `epimetheus` (epi) - Main server with desktop environment
- `proxmox-vm` - Docker host for containerized services
- `igpu` - GPU passthrough capable host (Intel Arc A310)
- `caddy` - Home Manager-only reverse proxy host
- `wsl` - Windows Subsystem for Linux development environment

**Audience:** System administrators, DevOps engineers, and developers seeking reproducible, declarative infrastructure management with NixOS.

---

## 2. System Architecture

### Components

```text
┌─────────────────────────────────────────────────────────────┐
│                        GitHub Repository                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐ │
│  │ flake.nix│  │ hosts.nix│  │  modules/│  │   docker/   │ │
│  └──────────┘  └──────────┘  └──────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions (CI/CD)                    │
│  • Nix Cleanup (automated linting & fixes)                   │
│  • Deploy (populate cache on push to master)                 │
│  • Rolling Flake Update (automated dependency updates)       │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                      Binary Caches                           │
│  • nixcache.ablz.au (priority 10)                           │
│  • nix-mirror.ablz.au (priority 20)                         │
│  • nixosconfig.cachix.org (priority 30)                     │
│  • cache.nixos.org (priority 40)                            │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Target Hosts                              │
│  Framework • Epimetheus • Proxmox VM • IGPU • WSL • Caddy   │
└─────────────────────────────────────────────────────────────┘
```

### Key Files

- **`flake.nix`** - Flake entry point with inputs, outputs, and host configurations
- **`hosts.nix`** - Host topology defining all managed systems
- **`modules/nixos/`** - NixOS system modules
- **`modules/home-manager/`** - Home Manager user modules
- **`hosts/*/`** - Per-host configuration and Home Manager files
- **`docker/*/`** - Declarative Docker Compose services
- **`nix/overlay.nix`** - Custom package overlays
- **`scripts/`** - Build and maintenance scripts
- **`ansible/`** - Supplementary Ansible playbooks for Proxmox hosts

---

## 3. Build Pipeline

### Trigger Schedule

- **On Push:** Automated cache population runs on every push to `master`
- **Nightly:** Rolling flake update at 22:15 AWST (automated PRs)
- **On Demand:** Manual workflow dispatch available

### Pipeline Steps

1. **Checkout Repository**

   ```bash
   git checkout master
   ```

2. **Evaluate Nix Flake**

   ```bash
   nix flake check
   ```

3. **Build All Host Configurations**
   - NixOS toplevels (includes integrated Home Manager)
   - Standalone Home Manager configurations

   ```bash
   ./scripts/populate_cache.sh
   ```

4. **Push to Binary Cache**
   - Automated via `cachix watch-exec`
   - Binaries pushed to `nixosconfig.cachix.org`

5. **Deploy (Manual)**
   - SSH to target hosts
   - Pull latest configurations
   - `nixos-rebuild switch --flake .#hostname`

### CI/CD Workflows

- **`.github/workflows/deploy.yml`** - Populate Cachix cache on push
- **`.github/workflows/nix-cleanup.yml`** - Automated linting and formatting
- **`.github/workflows/rolling-flake-update-pr.yml`** - Automated dependency updates

---

## 4. Setup & Requirements

### Prerequisites

- **Nix ≥ 2.18** with flakes enabled
- **Git**
- **SSH access** to target hosts
- **Cachix credentials** (for pushing to cache)

### Initial Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/abl030/nixosconfig.git
   cd nixosconfig
   ```

2. **Enable flakes** (if not already enabled):

   ```bash
   mkdir -p ~/.config/nix
   echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
   ```

3. **Enter development shell:**

   ```bash
   nix develop
   ```

   This provides:
   - Formatter (`nix fmt`)
   - Linters (statix, deadnix)
   - Development tools

### Configuration

**Environment Variables:**

- `CACHIX_AUTH_TOKEN` - For pushing to Cachix (CI only)
- `GITHUB_TOKEN` - For automated PRs and GitHub API access

**Secrets Management:**

- Secrets stored in `secrets/secrets.yaml` (encrypted with sops)
- Age keys required for decryption
- See `secrets/sops_home.nix` for sops configuration

---

## 5. Local Testing

### Build Specific Host

```bash
# Build NixOS configuration (includes Home Manager)
nix build .#nixosConfigurations.framework.config.system.build.toplevel

# Build standalone Home Manager configuration
nix build .#homeConfigurations.caddy.activationPackage
```

### Check All Configurations

```bash
# Validate all flake outputs
nix flake check

# Run linters
./scripts/linting.sh
```

### Test Changes Locally

```bash
# Dry-run (shows what would change)
sudo nixos-rebuild dry-activate --flake .#framework

# Test activation without bootloader changes
sudo nixos-rebuild test --flake .#framework

# Apply and make persistent
sudo nixos-rebuild switch --flake .#framework
```

### Replicate CI Builds

```bash
# Build all hosts (mimics CI)
./scripts/populate_cache.sh

# Format all Nix files
nix fmt
```

---

## 6. Continuous Integration Details

### Workflow Triggers

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `deploy.yml` | Push to master, Manual | Populate binary cache |
| `nix-cleanup.yml` | Push, PR | Automated linting and fixes |
| `rolling-flake-update-pr.yml` | Schedule (22:15 AWST) | Update flake inputs |

### Job Matrix

- **Architectures:** x86_64-linux (primary)
- **Hosts:** All hosts defined in `hosts.nix`
- **Channels:** nixpkgs-unstable (master branch)

### Caching Strategy

**Substituter Priority:**

1. `nixcache.ablz.au` (priority 10) - Self-hosted cache
2. `nix-mirror.ablz.au` (priority 20) - Mirror
3. `nixosconfig.cachix.org` (priority 30) - Cachix
4. `cache.nixos.org` (priority 40) - Official NixOS cache

**Trusted Public Keys:**

```nix
trusted-public-keys = [
  "ablz.au-1:EYnQ/c34qSA7oVBHC1i+WYh4IEkFSbLQdic+vhP4k54="
  "nixosconfig.cachix.org-1:whoVlEsbDSqKiGUejiPzv2Vha7IcWIZWXue0grLsl2k="
  "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
]
```

### Log Access

- **GitHub Actions:** View logs in the "Actions" tab of the repository
- **Self-hosted runner:** Logs available on runner host
- **Cachix:** Build logs at <https://app.cachix.org/>

### Artifact Retention

- **Binary cache:** Indefinite retention on Cachix and self-hosted cache
- **GitHub Actions logs:** 90 days (default)
- **Workflow artifacts:** 90 days (default)

### Failure Notifications

- GitHub Actions sends notifications to repository watchers
- CI failures appear in PR checks

---

## 7. Deployment

### Production Deployment

Successful builds are deployed to target hosts via:

1. **Manual SSH Deployment:**

   ```bash
   # SSH to target host
   ssh abl030@framework

   # Pull latest changes
   cd ~/nixosconfig
   git pull

   # Apply configuration
   sudo nixos-rebuild switch --flake .#framework
   ```

2. **Remote Deployment (from dev machine):**

   ```bash
   # Deploy to remote host
   nixos-rebuild switch --flake .#framework --target-host framework --use-remote-sudo
   ```

### Docker Services

Docker Compose services are managed declaratively:

- Service definitions: `docker/*/docker-compose.nix`
- Activated automatically on system rebuild
- Logs: `docker compose -f /run/current-system/sw/... logs`

### Rollback Procedure

**NixOS System:**
```bash
# List generations
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Rollback to previous generation
sudo nixos-rebuild switch --rollback

# Rollback to specific generation
sudo /nix/var/nix/profiles/system-42-link/bin/switch-to-configuration switch
```

**Home Manager:**
```bash
# List generations
home-manager generations

# Rollback to specific generation
/nix/store/xxx-home-manager-generation/activate
```

**Flake Lock:**
```bash
# Revert flake.lock to specific commit
git checkout <commit-hash> flake.lock
sudo nixos-rebuild switch --flake .#framework
```

---

## 8. Contributing

### Branching Model

- **`master`** - Stable configurations (protected)
- **`bot/rolling-flake-update`** - Automated dependency updates
- Feature branches: `feature/<description>`
- Bugfix branches: `fix/<description>`

### Commit Conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Formatting changes
- `refactor`: Code restructuring
- `chore`: Maintenance tasks
- `ci`: CI/CD changes

**Examples:**
```
feat(hosts): add new proxmox-vm2 configuration
fix(docker): correct immich environment variables
docs: update README with deployment instructions
```

### Code Review Rules

1. All changes require PR review before merge to `master`
2. CI checks must pass (linting, flake check)
3. Test changes locally before submitting PR
4. Document breaking changes in PR description

### Testing and Linting

**Format code:**
```bash
nix fmt
```

**Run linters:**
```bash
./scripts/linting.sh
```

**Check configurations:**
```bash
nix flake check
```

**Review linter output:**
```bash
cat .github/llm/NIX_LINT_PATCH_PROMPT.txt
```

---

## 9. Troubleshooting

### Common Errors

#### Hash Mismatch
```
error: hash mismatch in fixed-output derivation
```
**Solution:**
1. Update the hash in the package definition
2. Use `nix-prefetch-url` or `nix-prefetch-git` to get correct hash
3. Or set hash to empty string temporarily to see expected hash

#### Cache Miss
```
warning: substituter 'https://cache.nixos.org' does not have a valid signature
```
**Solution:**
```bash
# Add trusted public keys to /etc/nix/nix.conf
trusted-public-keys = nixosconfig.cachix.org-1:whoVlEsbDSqKiGUejiPzv2Vha7IcWIZWXue0grLsl2k= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
```

#### GC Roots
```
error: cannot delete path '/nix/store/...' since it is still alive
```
**Solution:**
```bash
# Remove old generations
sudo nix-collect-garbage -d

# Or keep last N generations
sudo nix-collect-garbage --delete-older-than 30d
```

#### Build Failures on Specific Host
```
error: builder for '/nix/store/...' failed
```
**Solution:**
1. Check host-specific configuration in `hosts/<hostname>/`
2. Verify hardware-configuration.nix is up to date
3. Test in VM: `nixos-rebuild build-vm --flake .#hostname`

#### Flake Lock Issues
```
error: unable to download 'https://github.com/...': HTTP error 404
```
**Solution:**
```bash
# Update flake inputs
nix flake update

# Or update specific input
nix flake lock --update-input nixpkgs
```

### Rebuilding from Scratch

```bash
# Clear local cache
nix-store --gc

# Rebuild without cache
sudo nixos-rebuild switch --flake .#framework --option substituters ""
```

### Docker Service Issues

```bash
# View service logs
docker compose -f <compose-file> logs -f

# Restart service
docker compose -f <compose-file> restart

# Rebuild after configuration change
sudo nixos-rebuild switch --flake .#proxmox-vm
```

### Secrets Decryption Failures

```bash
# Verify age key exists
ls -l ~/.config/sops/age/keys.txt

# Re-encrypt secrets
cd secrets/
sops -d secrets.yaml | sops -e /dev/stdin > secrets.yaml
```

---

## 10. License & Acknowledgements

### License

This configuration is released under the [MIT License](LICENSE) (or specify your license).

### Credits

- **[NixOS](https://nixos.org/)** - The purely functional Linux distribution
- **[Home Manager](https://github.com/nix-community/home-manager)** - Declarative user environment management
- **[Cachix](https://cachix.org/)** - Binary cache hosting
- **[nixos-hardware](https://github.com/NixOS/nixos-hardware)** - Hardware-specific configurations
- **[sops-nix](https://github.com/Mic92/sops-nix)** - Secrets management
- **[NvChad](https://nvchad.com/)** - Neovim configuration framework

### Upstream Configurations

Inspired by and incorporating patterns from:
- [gaj-shared](https://gitlab.com/gaj-nixos/shared) - Shared NixOS configurations
- Various community NixOS configurations and best practices

---

## Additional Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Nix Package Search](https://search.nixos.org/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [Nix Flakes](https://nixos.wiki/wiki/Flakes)

## Support

For issues and questions:
- Open an issue in this repository
- Check existing issues and discussions
- Review the NixOS Wiki and forums

---

**Last Updated:** October 2025
