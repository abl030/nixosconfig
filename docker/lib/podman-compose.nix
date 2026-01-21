{
  config,
  lib,
  pkgs,
}: let
  inherit (config.homelab) user userHome;
  inherit (config.homelab.containers) dataRoot;
  podmanCompose = "${pkgs.podman-compose}/bin/podman-compose";
  sopsBin = "${pkgs.sops}/bin/sops";
  ageKey = "${userHome}/.config/sops/age/keys.txt";
  baseDepends = lib.optionals config.homelab.containers.enable [
    "podman-system-service.service"
  ];

  mkEnvArgs = envFiles:
    lib.concatStringsSep " " (map (env: "--env-file ${env.runFile}") envFiles);

  mkDecryptSteps = envFiles:
    map (env: ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${sopsBin} -d --output ${env.runFile} ${env.sopsFile}'') envFiles;

  mkRunEnvPaths = envFiles:
    lib.concatStringsSep " " (map (env: env.runFile) envFiles);

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
        "/run/current-system/sw/bin/mkdir -p /run/user/%U/secrets"
      ];
    decrypt = mkDecryptSteps envFiles;
    chmod =
      if envFiles == []
      then []
      else [
        "/run/current-system/sw/bin/chmod 600 ${mkRunEnvPaths envFiles}"
      ];
  in
    base ++ preStart ++ decrypt ++ chmod;

  mkEnv = projectName: extraEnv:
    [
      "COMPOSE_PROJECT_NAME=${projectName}"
      "DATA_ROOT=${dataRoot}"
      "HOME=${userHome}"
      "XDG_RUNTIME_DIR=/run/user/%U"
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
      restartIfChanged = true;
      reloadIfChanged = false;

      unitConfig = mkMountRequirements requiresMounts;
      inherit requires;
      wants = wants ++ baseDepends;
      after = after ++ baseDepends;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
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
