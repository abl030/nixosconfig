{
  # Fleet signing trust model and rollout/recovery runbook:
  # docs/wiki/infrastructure/signed-fleet-deploys.md
  config,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  signingKeys = hostConfig.signingKeys or [];
  explicitPrimarySigningKeys = lib.filter (entry: entry.primary or false) signingKeys;
  primarySigningKey =
    if signingKeys == []
    then null
    else if explicitPrimarySigningKeys != []
    then builtins.head explicitPrimarySigningKeys
    else if builtins.length signingKeys == 1
    then builtins.head signingKeys
    else null;
  signingKeyPath =
    if primarySigningKey == null
    then null
    else primarySigningKey.privateKeyPath or "${config.home.homeDirectory}/.ssh/id_ed25519_git_sign";
  ghCredentialHelper = "!${lib.getExe pkgs.gh} auth git-credential";
  gitSafeDirectories = hostConfig.gitSafeDirectories or [];
in {
  assertions = [
    {
      assertion = builtins.length explicitPrimarySigningKeys <= 1;
      message = "hostConfig.signingKeys must not mark more than one primary signing key";
    }
    {
      assertion = signingKeys == [] || primarySigningKey != null;
      message = "hostConfig.signingKeys with multiple keys must mark exactly one entry with primary = true for local git signing";
    }
  ];

  programs.git = {
    enable = true;

    settings =
      [
        {
          user = {
            name = hostConfig.gitUserName or "abl030";
            email = hostConfig.gitUserEmail or "abl030@gmail.com";
          };
          credential = {
            helper = ghCredentialHelper;
            "https://github.com".helper = [
              ""
              ghCredentialHelper
            ];
            "https://gist.github.com".helper = [
              ""
              ghCredentialHelper
            ];
          };
        }
      ]
      ++ lib.optional (primarySigningKey != null) {
        gpg.ssh.allowedSignersFile = "/etc/fleet-update/allowed_signers";
      }
      ++ lib.optional (gitSafeDirectories != []) {
        safe.directory = gitSafeDirectories;
      };

    signing = lib.mkIf (primarySigningKey != null) {
      format = "ssh";
      key = signingKeyPath;
      signByDefault = true;
    };
  };

  home.activation.gitSigningWarnings = lib.hm.dag.entryAfter ["writeBoundary"] ''
    legacy_gitconfig="${config.home.homeDirectory}/.gitconfig"
    if [ -e "$legacy_gitconfig" ]; then
      echo "warning: $legacy_gitconfig exists and can override Home Manager's git config; remove it after checking credential helpers are present in ~/.config/git/config"
    fi

    ${lib.optionalString (primarySigningKey != null) ''
      signing_key="${signingKeyPath}"
      if [ ! -r "$signing_key" ]; then
        echo "warning: git signing key missing or unreadable: $signing_key"
        echo "warning: generate it with: ssh-keygen -t ed25519 -N \"\" -C \"git-signing:${hostConfig.hostname}\" -f \"$signing_key\""
      fi
    ''}
  '';
}
