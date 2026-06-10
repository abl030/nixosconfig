{lib}: let
  hasWhitespace = value:
    lib.any (needle: lib.hasInfix needle value) [" " "\t"];

  quotePrincipal = principal:
    if hasWhitespace principal || lib.hasInfix "\"" principal
    then "\"${lib.replaceStrings ["\\" "\""] ["\\\\" "\\\""] principal}\""
    else principal;

  hostEntries = hosts:
    lib.flatten (
      lib.mapAttrsToList (
        name: host:
          lib.map (entry: entry // {host = name;}) (host.signingKeys or [])
      )
      (lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts)
    );

  serviceEntries = hosts:
    lib.map (entry: entry // {host = "_signingPrincipals";}) (hosts._signingPrincipals or []);

  entries = hosts: hostEntries hosts ++ serviceEntries hosts;

  renderAllowedSigner = entry: let
    principal = entry.principal or "";
    key = entry.key or "";
  in "${quotePrincipal principal} namespaces=\"git\" ${key}";

  keyLooksValid = key:
    builtins.match "ssh-ed25519 [A-Za-z0-9+/=]+( .*)?" key != null;

  validationErrors = hosts: let
    allEntries = entries hosts;
    botEntries = lib.filter (entry: entry.principal == "nix bot <acme@ablz.au>") allEntries;
  in
    lib.flatten (
      lib.imap0 (
        index: entry:
          lib.optionals (!(entry ? principal) || entry.principal == "") [
            "signing entry ${toString index} is missing principal"
          ]
          ++ lib.optionals (!(entry ? key) || entry.key == "") [
            "signing entry ${toString index} is missing key"
          ]
          ++ lib.optionals (entry ? key && !keyLooksValid entry.key) [
            "signing entry ${toString index} has malformed ed25519 key: ${entry.key}"
          ]
      )
      allEntries
    )
    ++ lib.optionals (botEntries == []) [
      "missing required nix bot <acme@ablz.au> signing principal"
    ];
in {
  inherit entries renderAllowedSigner validationErrors;

  allowedSignersText = hosts:
    lib.concatMapStringsSep "\n" renderAllowedSigner (entries hosts) + "\n";
}
