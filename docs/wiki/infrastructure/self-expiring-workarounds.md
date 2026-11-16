# Self-expiring workarounds

**Date:** 2026-11-17
**Status:** policy. Insecure exemptions shipped 2026-11-17; the other mechanisms
listed below already existed.

## Rule

Every temporary workaround must carry a machine check that fires when the
workaround is no longer needed. That covers a package hold, an input pin, an
insecure permit, an upstream-bug override, and a version-gated patch. "Remember to
remove this later" in a comment doesn't count. If the check would block the
fleet, make the nightly rolling update warn and notify instead, and keep the hard
failure in `nix flake check`. A dead workaround is cleanup, not danger, and must
never hold back nixpkgs security updates (the zotero lesson, 2026-10).

## Mechanisms (reuse these before inventing one)

| Workaround | Lives in | Expiry signal |
|---|---|---|
| Package hold (leaf on older nixpkgs) | `nix/held-packages.json` + `nixpkgs-held` | Rolling update test-builds on each nixpkgs move and auto-releases; warns past 30 days. See [rolling-flake-update.md](rolling-flake-update.md). |
| Input hold (input on own nixpkgs) | `flake.nix` `NIXPKGS-OWN-OK` marker + `held-packages.json` `kind = "input"` | Auto-released when the input builds on fleet nixpkgs. `nixpkgsFollowsCheck` rejects unmarked own-nixpkgs inputs. |
| Insecure permit (`knownVulnerabilities`) | `nix/insecure-exemptions.json` | `insecureExemptionsFresh` fails once `neededBy` evaluates without the permit. Rolling warns nightly and pings Gotify. |
| Dated EOL deadline | e.g. `nix/lib/mongodb80-eol.nix` | Pure date check, fatal in checks and rolling after the deadline. |

## Insecure exemptions

- **Registry:** `nix/insecure-exemptions.json`, keyed by exact `pname-version`.
  Each entry has `neededBy` (the attribute path that pulls it in), `hosts`
  (hosts.nix names), `since`, `reason` and `tracking`. All fields are required;
  `insecureExemptionsRegistry` enforces that.
- **Scope:** `modules/nixos/profiles/base.nix` permits only the host's own
  entries. The shared flake `pkgs` used by standalone `homeConfigurations`
  carries them all, because those configs share one package set.
- **No ad hoc permits:** `insecureExemptionsRegistry` fails if
  `permittedInsecurePackages`, `allowInsecurePredicate` or
  `NIXPKGS_ALLOW_INSECURE` appears in any `.nix`, `.sh` or `.py` file outside the
  registry plumbing.
- **Expiry:** `nix/lib/insecure-exemptions.nix` `stale` imports nixpkgs with
  **no** permits and checks whether each `neededBy` now evaluates (or has
  vanished). `checks.insecureExemptionsFresh` throws `STALE INSECURE EXEMPTION`.
  `populate_cache.sh` skips that one check, and `rolling_flake_update.sh`
  `check_insecure_exemptions` adds a ⚠️ summary line and a Gotify instead.
- **The other direction is already loud:** permits match the exact version, so if
  the dependency moves to a *different* insecure version, host evaluation fails.

### Current entries

- `firefox-esr-140-bin-unwrapped-140.17.0esr`, needed by `zotero` on epi and
  framework, since 2026-11-17. Zotero is a XUL app on Firefox's Gecko runtime,
  and its build overlays Zotero's `app/` onto a stock Firefox tarball pinned in
  Zotero's `app/config.sh`. Every 10.0.x release pins ESR 140, which reached EOL
  on 2026-10-13. Zotero's `main` moved to ESR 153 (`25fa4a01de`, now
  153.6.0esr), but no release has been cut from it. nixpkgs is actively
  maintained and follows Zotero's pin. Patching nixpkgs would mean backporting
  Zotero's Gecko port, so we wait for the release. The zotero package hold this
  replaced was no safer, since the held build also ran ESR 140.
