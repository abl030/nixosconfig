# `forgejo-push` / `forgejo-ls-remote`: fixed-argument front ends for
# scripts/forgejo-auth.sh on doc1 (#227). They always act on the checkout that
# contains $PWD, with the nixosconfig Forgejo URLs and the nixbot token baked
# in, so an agent's command line carries no git operand or `.git` URL. That is
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
  url = "https://git.ablz.au/abl030/nixosconfig.git";
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
        exec ${forgejoAuth} ${subcommand} \
          --repo "$repo" --remote origin \
          --expected-fetch-url ${url} \
          --expected-push-url ${url} \
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
