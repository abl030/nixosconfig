# doc1's Forgejo git access. Plain git (clone/fetch/pull/push) works through
# the system credential helper at the bottom of this file. Additionally,
# `forgejo-push` / `forgejo-ls-remote` are fixed-argument front ends for
# scripts/forgejo-auth.sh on doc1 (#227). They always act on the checkout that
# contains $PWD, with the nixbot token baked in. The checkout's `origin` URL
# must be one of `pushModes` below (nixbot must also be a write collaborator
# on that repo), so an agent's command line carries no git operand or `.git` URL. That is
# the shape Claude Code's background-job worktree guard can accept; see
# docs/wiki/claude-code/background-job-worktree-guard.md. All URL, token and
# trace checks stay inside forgejo-auth.sh. LFS repos push through its
# git-lfs-push mode (Basic auth via its own credential helper, HTTP/1.1); see
# docs/wiki/services/forgejo.md (LFS).
{
  lib,
  pkgs,
  config,
  ...
}: let
  forgejoAuth = pkgs.writeTextFile {
    name = "forgejo-auth.sh";
    executable = true;
    text = lib.replaceStrings ["#!/usr/bin/env -S bash -p"] ["#!${pkgs.bash}/bin/bash -p"] (builtins.readFile ../../scripts/forgejo-auth.sh);
  };
  # Repos a doc1 agent may push to with the nixbot token, and the
  # forgejo-auth.sh push mode each one needs.
  pushModes = {
    "https://git.ablz.au/abl030/nixosconfig.git" = "git-push";
    "https://git.ablz.au/abl030/cullen-carbon.git" = "git-lfs-push";
    # Agent-maintained Cullen assistant workspace (~/cullen-assistant).
    "https://git.ablz.au/abl030/cullen-assistant.git" = "git-push";
  };
  tokenFile = config.sops.secrets."forgejo/nixbot-token".path;

  # Plain-git credential helper: answers `get` for https://git.ablz.au only
  # (forgejo-auth.sh git-credential), re-reading the 0400 token file each time;
  # store/erase are ignored so nothing persists it. Git appends the operation.
  forgejoGitCredential = pkgs.writeShellScript "forgejo-git-credential" ''
    exec ${forgejoAuth} git-credential --token-file ${tokenFile} "$@"
  '';

  mkForgejoCommand = {
    name,
    subcommandFor,
    argName,
    argFlag,
    argDefault,
  }:
    pkgs.writeShellApplication {
      inherit name;
      # git-lfs: an LFS repo's pre-push hook runs `git lfs pre-push`.
      runtimeInputs = [pkgs.git pkgs.git-lfs];
      text = ''
        if [ "$#" -gt 1 ] || [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "--help" ]; then
          echo "usage: ${name} [${argName}]   (default: ${argDefault}; acts on the checkout containing \$PWD)" >&2
          exit 2
        fi
        repo="$(git rev-parse --show-toplevel)"
        url="$(git -C "$repo" remote get-url origin)"
        case "$url" in
        ${lib.concatStrings (lib.mapAttrsToList (url: mode: ''
            ${lib.escapeShellArg url}) subcommand=${subcommandFor mode} ;;
          '')
          pushModes)}  *)
            echo "${name}: origin $url is not an allowlisted Forgejo repo" >&2
            exit 1
            ;;
        esac
        exec ${forgejoAuth} "$subcommand" \
          --repo "$repo" --remote origin \
          --expected-fetch-url "$url" \
          --expected-push-url "$url" \
          --token-file ${tokenFile} \
          ${argFlag} "''${1:-${argDefault}}"
      '';
    };
in {
  environment.systemPackages = [
    (mkForgejoCommand {
      name = "forgejo-push";
      subcommandFor = mode: mode;
      argName = "REFSPEC";
      argFlag = "--refspec";
      argDefault = "HEAD:master";
    })
    (mkForgejoCommand {
      name = "forgejo-ls-remote";
      subcommandFor = _: "git-ls-remote";
      argName = "REF";
      argFlag = "--ref";
      argDefault = "refs/heads/master";
    })
    # LFS repos (cullen-carbon) need git-lfs for checkout/pull/push with plain git.
    pkgs.git-lfs
  ];

  # Plain `git clone/fetch/pull/push` against git.ablz.au from doc1, for every
  # repo nixbot can reach (nixosconfig, cullen-carbon, cullen-assistant...).
  # Same token and same Forgejo-side limits as forgejo-push (per-repo
  # collaborator rights, master branch protection); the token file is already
  # abl030-owned, so this exposes it to nothing new. Lives in /etc/gitconfig so
  # it applies to every checkout and worktree. The leading "" drops any helper
  # inherited for this URL. HTTP/1.1: git-lfs 3.7.1 panics on HTTP/2 uploads to
  # this server. Never set GIT_TRANSFER_TRACE against it (Forgejo echoes the
  # credential into LFS batch bodies). See docs/wiki/services/forgejo.md.
  programs.git = {
    enable = true;
    config = {
      credential."https://git.ablz.au".helper = ["" "${forgejoGitCredential}"];
      http."https://git.ablz.au".version = "HTTP/1.1";
    };
  };
}
