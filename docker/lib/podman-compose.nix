{
  config,
  lib,
  pkgs,
}: let
  inherit (config.homelab) user userHome;
  inherit (config.homelab.containers) dataRoot;
  userUid = let
    uid = config.users.users.${user}.uid or null;
  in
    if uid == null
    then 1000
    else uid;
  userGroup = config.users.users.${user}.group or "users";
  runUserDir = "/run/user/${toString userUid}";
  podmanCompose = "${pkgs.podman-compose}/bin/podman-compose";
  sopsBin = "${pkgs.sops}/bin/sops";
  ageKey = "${userHome}/.config/sops/age/keys.txt";
  sopsDecryptScript = pkgs.writeShellScript "podman-sops-decrypt" ''
    set -euo pipefail
    out="$1"
    in="$2"
    if [[ -f /var/lib/sops-nix/key.txt ]]; then
      exec /run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt ${sopsBin} -d --output "$out" "$in"
    fi
    if [[ -f "${ageKey}" ]]; then
      exec /run/current-system/sw/bin/env SOPS_AGE_KEY_FILE="${ageKey}" ${sopsBin} -d --output "$out" "$in"
    fi
    echo "No sops identity found (expected /var/lib/sops-nix/key.txt, ${ageKey}, or /etc/ssh/ssh_host_ed25519_key)" >&2
    exit 1
  '';
  baseDepends = lib.optionals config.homelab.containers.enable [
    "podman-system-service.service"
  ];

  normalizeEnvFiles = envFiles:
    map
    (env:
      env
      // {
        runFile = lib.replaceStrings ["/run/user/%U"] [runUserDir] env.runFile;
      })
    envFiles;

  mkEnvArgs = envFiles:
    lib.concatStringsSep " " (map (env: "--env-file ${env.runFile}") (normalizeEnvFiles envFiles));

  mkDecryptSteps = envFiles:
    map
    (env: ''${sopsDecryptScript} ${env.runFile} ${env.sopsFile}'')
    (normalizeEnvFiles envFiles);

  mkRunEnvPaths = envFiles:
    lib.concatStringsSep " " (map (env: env.runFile) (normalizeEnvFiles envFiles));

  mkMountRequirements = requiresMounts: let
    merged = [dataRoot] ++ requiresMounts;
  in
    if merged == []
    then {}
    else {RequiresMountsFor = merged;};

  mkExecStartPre = envFiles: preStart: let
    base =
      if envFiles == []
      then []
      else [
        "/run/current-system/sw/bin/mkdir -p ${runUserDir}/secrets"
      ];
    decrypt = mkDecryptSteps envFiles;
    chmod =
      if envFiles == []
      then []
      else [
        "/run/current-system/sw/bin/chmod 600 ${mkRunEnvPaths envFiles}"
      ];
    chown =
      if envFiles == []
      then []
      else [
        "/run/current-system/sw/bin/chown ${user}:${userGroup} ${mkRunEnvPaths envFiles}"
      ];
  in
    base ++ preStart ++ decrypt ++ chmod ++ chown;

  mkEnv = projectName: extraEnv:
    [
      "COMPOSE_PROJECT_NAME=${projectName}"
      "DATA_ROOT=${dataRoot}"
      "HOME=${userHome}"
      "XDG_RUNTIME_DIR=${runUserDir}"
      "PATH=/run/current-system/sw/bin:/run/wrappers/bin"
    ]
    ++ extraEnv;

  mkService = {
    stackName,
    description,
    projectName,
    composeFile,
    envFiles ? [],
    extraEnv ? [],
    preStart ? [],
    requiresMounts ? [],
    after ? [],
    wants ? [],
    requires ? [],
    restart ? "on-failure",
    restartSec ? "30s",
  }: {
    systemd.services.${stackName} = {
      inherit description;
      restartIfChanged = false;
      reloadIfChanged = false;

      unitConfig = mkMountRequirements requiresMounts;
      inherit requires;
      wants = wants ++ baseDepends;
      after = after ++ baseDepends;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        PermissionsStartOnly = true;
        Environment = mkEnv projectName extraEnv;

        ExecStartPre = mkExecStartPre envFiles preStart;

        ExecStart = "${podmanCompose} -f ${composeFile} ${mkEnvArgs envFiles} up -d --remove-orphans";
        ExecStop = "${podmanCompose} -f ${composeFile} ${mkEnvArgs envFiles} down";
        ExecReload = "${podmanCompose} -f ${composeFile} ${mkEnvArgs envFiles} up -d --remove-orphans";

        Restart = restart;
        RestartSec = restartSec;
        StandardOutput = "journal";
        StandardError = "journal";
      };

      wantedBy = ["multi-user.target"];
    };
  };
in {
  inherit mkService;
}
