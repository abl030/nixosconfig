# `forgejo-push` / `forgejo-ls-remote`: fixed-argument front ends for
# scripts/forgejo-auth.sh on doc1 (#227). They always act on the checkout that
# contains $PWD, with the nixbot token baked in. The checkout's `origin` URL
# must be one of `allowedUrls` below (nixbot must also be a write collaborator
# on that repo), so an agent's command line carries no git operand or `.git` URL. That is
# the shape Claude Code's background-job worktree guard can accept; see
# docs/wiki/claude-code/background-job-worktree-guard.md. All URL, token and
# trace checks stay inside forgejo-auth.sh.
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
  # Repos a doc1 agent may push to with the nixbot token.
  allowedUrls = [
    "https://git.ablz.au/abl030/nixosconfig.git"
    "https://git.ablz.au/abl030/cullen-carbon.git"
  ];
  tokenFile = config.sops.secrets."forgejo/nixbot-token".path;

  mkForgejoCommand = {
    name,
    subcommand,
    argName,
    argFlag,
    argDefault,
  }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [pkgs.git];
      text = ''
        if [ "$#" -gt 1 ] || [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "--help" ]; then
          echo "usage: ${name} [${argName}]   (default: ${argDefault}; acts on the checkout containing \$PWD)" >&2
          exit 2
        fi
        repo="$(git rev-parse --show-toplevel)"
        url="$(git -C "$repo" remote get-url origin)"
        case "$url" in
          ${lib.concatMapStringsSep " | " lib.escapeShellArg allowedUrls}) ;;
          *)
            echo "${name}: origin $url is not an allowlisted Forgejo repo" >&2
            exit 1
            ;;
        esac
        exec ${forgejoAuth} ${subcommand} \
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
      subcommand = "git-push";
      argName = "REFSPEC";
      argFlag = "--refspec";
      argDefault = "HEAD:master";
    })
    (mkForgejoCommand {
      name = "forgejo-ls-remote";
      subcommand = "git-ls-remote";
      argName = "REF";
      argFlag = "--ref";
      argDefault = "refs/heads/master";
    })
  ];
}
