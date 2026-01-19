# Repository Guidelines

Always run `check` before committing changes.
Always run `tofu-plan` before any `tofu-apply`.
Respect stabilization rules for all new edits:
- Isolate assets/scripts/config sources with `builtins.path` or `writeTextFile` to avoid flake-source churn.
- Avoid relying on module import order for list options; use `lib.mkOrder` when order must be stable.

## VM Automation Notes

- `pve new` runs the interactive wizard (`nix run .#new-vm`) and stages `hosts/<name>`, `hosts.nix`, and `vms/definitions.nix`.
- `pve provision <name>` provisions an existing config/definition via `nix run .#provision-vm <name>`.
- `pve integrate <name> <ip> <vmid>` runs `nix run .#post-provision-vm ...` for fleet integration.
- Post-provision expects SOPS identity; it mirrors the `dc` lookup order (env vars, age key files, host key, user key).
- New hosts default to a temp password hash (`temp123`) in `vms/new.sh`.

## Project Structure & Module Organization

- `flake.nix`, `hosts.nix`: entry points and host inventory (single source of truth).
- `hosts/`: per-host NixOS configs (e.g., `hosts/framework/configuration.nix`).
- `modules/nixos/`, `modules/home-manager/`: reusable NixOS and Home Manager modules.
- `home/`: Home Manager configuration and app settings.
- `nix/`: devshell, formatter, and helper apps (e.g., `nix/devshell.nix`).
- `vms/`: Proxmox VM automation and definitions.
- `secrets/`: sops-nix encrypted data and `.sops.yaml`.
- `scripts/`, `ansible/`, `docker/`, `docs/`: operational tooling and docs.

## Build, Test, and Development Commands

- `nix develop`: enter the dev shell with formatter and linting tools.
- `nix fmt`: format all Nix files with Alejandra (write in place).
- `nix run .#fmt-nix -- --check`: list files that would change without writing.
- `nix run .#lint-nix`: run deadnix + statix across the repo.
- `check`: full quality gate (format check, deadnix, statix, `nix flake check`).
- `nix flake check`: build and validate all configurations.
- `nixos-rebuild switch --flake .#<hostname>`: deploy locally.
- `nixos-rebuild switch --flake .#<hostname> --target-host <hostname>`: deploy remote.

## Coding Style & Naming Conventions

- Nix formatting is enforced via Alejandra (`nix fmt`), so let the formatter decide layout.
- Run deadnix for unused declarations and statix for style/lint issues.
- Prefer explicit, descriptive module names under `modules/nixos/` and `modules/home-manager/`.
- Keep host names consistent with `hosts.nix` and `hosts/<name>/`.

## Testing Guidelines

- There is no separate unit test suite; validation is via `nix flake check`.
- Use `check` before committing; it fails fast on formatting or lint issues.
- If adding scripts, ensure shellcheck warnings are addressed or justified.

## Commit & Pull Request Guidelines

- Recent commits follow a Conventional Commits style like `fix(pve): ...`; keep messages short and scoped when possible.
- If a change is operational or host-specific, mention the host, module, or subsystem in the subject.
- PRs should describe impact, commands run (`check`, `nix flake check`), and any deployment notes.

## Security & Secrets

- Secrets live under `secrets/` and are managed with sops-nix; do not commit plaintext.
- Update keys via `sops updatekeys --yes <file>` after adding a new host key to `secrets/.sops.yaml`.
