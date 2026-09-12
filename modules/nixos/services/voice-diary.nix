# voice-diary — phone voice recordings in, dated transcript pairs out.
#
# The user records a spoken diary entry in the car (Easy Voice Recorder on the
# phone). Syncthing replicates the recordings folder to doc2 as a RECEIVE-ONLY
# folder. This service scans that drop directory on a timer, transcribes each
# new recording through the self-hosted whisper endpoint, and writes a
# date-prefixed audio + transcript pair into an inbox directory for the user to
# file into their Zettelkasten diary by hand.
#
# Three decisions worth knowing before changing anything here:
#
#   1. TIMER, NOT A PATH UNIT. The drop and inbox directories are on /mnt/data,
#      which is NFS from tower. inotify does not work over NFS, so a
#      systemd.path unit would silently never fire. A periodic scan is the only
#      reliable trigger.
#
#   2. THE DROP DIRECTORY IS TRANSIENT STAGING, NOT AN ARCHIVE. It mirrors
#      whatever is on the phone: delete a recording there and it disappears
#      here too, which is intended. The durable copy is the inbox pair the
#      ingest writes, and nothing in this pipeline deletes from the inbox.
#      Receive-only therefore buys exactly one thing — doc2 never *sends* its
#      local changes, so a bug here cannot destroy an original on the phone
#      that has not been archived yet. It does not, and should not, block
#      deletions arriving from the phone. The bind below is read-only so the
#      ingest cannot write to staging even by accident.
#
#   3. NO AI IN THE LOOP. Filing is deterministic — the date comes from the
#      recording's mtime and the name sorts chronologically. Summarising or
#      titling would need a model, and that is deliberately not here. If it is
#      added later it should use the fleet's own llama-cpp on igpu, not a
#      third-party API; these are personal diary entries.
#
# See docs/wiki/services/voice-diary.md for the pipeline, and
# docs/wiki/services/whisper-vad-long-audio.md for why the transcription side
# needs VAD and a raised proxy timeout.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.voiceDiary;

  ingestScript = builtins.path {
    path = ../../../scripts/voice-diary-ingest.py;
    name = "voice-diary-ingest.py";
  };

  ingest = pkgs.writeShellScript "voice-diary-ingest" ''
    set -euo pipefail
    exec ${pkgs.python3}/bin/python3 ${ingestScript}
  '';
in {
  options.homelab.services.voiceDiary = {
    enable = lib.mkEnableOption "voice recording ingest + transcription";

    user = lib.mkOption {
      type = lib.types.str;
      default = "abl030";
      description = ''
        User the ingest runs as. Defaults to the owner of the NFS tree; the
        recordings and the inbox are personal files, and running as a dedicated
        system user would only add an ownership problem on an NFS share that
        already maps to this user.
      '';
    };

    dropDir = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/data/Life/Andy/VoiceRecordings";
      description = ''
        Directory Syncthing replicates the phone's recordings into. Transient
        staging, not an archive — it mirrors the phone, so deleting a recording
        there removes it here too. The durable copy is the pair written to
        `inboxDir`.

        Bound READ-ONLY into the unit so the ingest cannot write to staging
        even by accident.
      '';
    };

    inboxDir = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/data/Life/Zet/Projects/Diary/Inbox";
      description = ''
        Directory the dated audio + transcript pairs are written into. The user
        files these into the diary by hand.
      '';
    };

    whisperUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://whisper.ablz.au/v1/audio/transcriptions";
      description = ''
        Transcription endpoint. Tailnet-only. The vhost needs a raised
        proxyTimeout — long recordings hold the request open for minutes.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "large";
      description = "whisper-server model alias (see homelab.services.whisper-server.models).";
    };

    prompt = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "This is a spoken diary. People mentioned: Meg, Harriet.";
      description = ''
        Vocabulary hint sent with each transcription request, to bias whisper
        toward recurring names.

        Sent per-request rather than configured as a whisper-server flag on
        purpose: the same endpoint serves the Dictate phone keyboard, and a
        diary-specific vocabulary should not bias that.

        It is a nudge, not a guarantee. Measured on a real recording it
        corrected "Vania" to "Vanya", but could not reach "Gerlinde" — the
        audio is acoustically closer to "Galinda" and the model returns that
        however it is primed. Names whisper cannot reach this way are fixed
        deterministically by NAME_FIXES in scripts/voice-diary-ingest.py.
      '';
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*:0/10";
      description = ''
        Scan interval. Ten minutes is deliberately unhurried: a diary entry has
        no latency requirement, whisper-server handles one request at a time,
        and a tighter loop would compete with the Dictate phone keyboard for
        the same backend.
      '';
    };

    minAgeSeconds = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = ''
        Ignore files modified within this window, so a recording still being
        replicated by Syncthing is not transcribed half-written.
      '';
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 3600;
      description = "Per-recording transcription timeout.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dropDir != cfg.inboxDir;
        message = "voiceDiary.dropDir and inboxDir must differ — the inbox is written to and the drop dir must stay read-only.";
      }
    ];

    systemd.services.voice-diary = {
      description = "Transcribe new phone voice recordings into the diary inbox";
      after = ["network-online.target" "remote-fs.target"];
      wants = ["network-online.target"];

      environment = {
        VOICE_DIARY_DROP_DIR = cfg.dropDir;
        VOICE_DIARY_INBOX_DIR = cfg.inboxDir;
        VOICE_DIARY_WHISPER_URL = cfg.whisperUrl;
        VOICE_DIARY_MODEL = cfg.model;
        VOICE_DIARY_PROMPT = cfg.prompt;
        VOICE_DIARY_TIMEOUT = toString cfg.timeoutSeconds;
        VOICE_DIARY_MIN_AGE = toString cfg.minAgeSeconds;
      };

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = ingest;

        NoNewPrivileges = true; # plain python; no setuid exec (#232)

        # doc2 default (#257): blank /mnt and bind back only what this unit
        # legitimately touches, so a compromise here cannot read the other NFS
        # exports. BindPaths (not ReadWritePaths) because the sources are on
        # NFS and must fail loudly rather than silently skip — a silently
        # missing rw bind would surface as EROFS hours later.
        TemporaryFileSystem = "/mnt";
        BindReadOnlyPaths = [cfg.dropDir];
        BindPaths = [cfg.inboxDir];

        ProtectSystem = "strict";
        ProtectHome = lib.mkForce "tmpfs";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service" "~@privileged" "~@resources"];
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];

        # Be a polite neighbour: transcription is GPU work on another host, but
        # the copy of a multi-MB recording over NFS shouldn't fight doc2's
        # real services.
        Nice = 10;
        IOSchedulingClass = "idle";

        TimeoutStartSec = "2h";
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "voice-diary";
      };
    };

    systemd.timers.voice-diary = {
      description = "Scan for new phone voice recordings to transcribe";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "60s";
      };
    };

    # Both directories live on the tower NFS export; a stale mount makes the
    # scan fail every tick until something restarts it.
    homelab.nfsWatchdog.voice-diary.path = "/mnt/data";

    # The ingest leaves a failed recording in place and retries on the next
    # tick, so an isolated "FAILED" line is self-healing noise and deliberately
    # not alerted. These two are not self-healing: NAMESPACE means a BindPaths
    # source vanished (the wiki requires this pattern wherever BindPaths is
    # used), and a missing drop dir means Syncthing is not delivering at all —
    # which from the user's side looks like recordings silently never arriving.
    homelab.monitoring.errorPatterns = [
      {
        name = "Voice diary ingest broken";
        unit = "voice-diary.service";
        pattern = "Failed at step NAMESPACE|drop dir missing";
        severity = "warning";
        summary = "voice-diary can't reach its recordings — new voice notes are not being transcribed";
      }
    ];

    # No homelab.monitoring.monitors entry and no localProxy: this is a timer,
    # not a server. It listens on nothing and has no URL to probe. Health is
    # covered by the errorPatterns above plus the whisper endpoint's own Kuma
    # monitor, which is the dependency that actually breaks.
  };
}
