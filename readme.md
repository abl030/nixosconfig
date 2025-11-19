# NixOS Configuration

A comprehensive, flake-based NixOS and Home Manager configuration.

## Highlights

- **Flake-parts**: Structured and modular flake definition.
- **Sops-nix**: Secure secret management.
- **Hybrid**: Supports full NixOS systems and standalone Home Manager setups.
- **NvChad**: Integrated Neovim configuration via `nvchad4nix`.
- **Automated Updates**: Daily `flake.lock` updates via GitHub Actions, with auto-merge and automatic system updates on all hosts.
- **CI/CD Gating**: All changes must pass `nix flake check` to ensure stable builds for all hosts.
- **WSL Support**: Dedicated configuration for Windows Subsystem for Linux.

## Modules

- **SSH**: Dynamic SSH configuration generation based on flake hosts.
- **Auto-update**: Automated nightly system updates and garbage collection.
- **Nix Cache**: Unified cache server with pull-through mirror and local binary cache.

## Hosts

- **epimetheus**: Main workstation.
- **framework**: Laptop.
- **caddy**: Server / Container (Home Manager only).
- **wsl**: WSL instance.
- **proxmox-vm**: VM testing.
- **igpu**: Integrated graphics testing.

## Usage

```bash
# Apply configuration directly from GitHub
nixos-rebuild switch --flake github:abl030/nixosconfig#<hostname>
```

