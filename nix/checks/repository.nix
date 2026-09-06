{pkgs}: let
  # Every flake input must FOLLOW the fleet nixpkgs, never carry its own.
  # A duplicate nixpkgs node in flake.lock drifts stale on its own (the
  # rolling-flake-update only advances the ROOT pin), bloats every closure
  # that pulls the input, and makes tooling/agents misread the fleet
  # nixpkgs version — exactly the orphan that left a stale "nixpkgs from
  # April" node lying in the lock. Deny-by-default: a genuine exception
  # needs a `# NIXPKGS-OWN-OK: <input> — <reason>` marker in flake.nix.
  # Detection is list-vs-string in flake.lock (follows = list, own = string
  # node-ref); see nix/checks/nixpkgs-follows-audit.py and
  # docs/wiki/infrastructure/nixpkgs-follows-policy.md.
  nixpkgsFollowsCheck = pkgs.runCommand "nixpkgs-follows-audit" {} ''
    ${pkgs.python3}/bin/python3 ${./nixpkgs-follows-audit.py} \
      ${../../flake.lock} ${../../flake.nix} || exit 1
    touch $out
  '';

  # Claude Code and Codex share authored instructions, skills, agents,
  # MCP declarations, and durable memory. Fail closed when a symlink is
  # broken, a generated Codex adapter drifts, a skill is undiscoverable,
  # or always-loaded context grows past its explicit budget.
  # See docs/wiki/claude-code/poly-ai-shared-surfaces.md.
  aiPortabilityCheck = let
    rcaCheckoutSafetyCheck = pkgs.writeText "check-rca-checkout-safety.py" ''
      import pathlib
      import re
      import sys

      FETCH = "git fetch origin"
      WORKTREE = 'git worktree add -b "$branch" "$worktree" origin/master'
      CAPTURE = 'git -C /home/abl030/nixosconfig status --short --branch >"$(git rev-parse --git-path primary-status-baseline)"'
      COMPARE = 'git -C /home/abl030/nixosconfig status --short --branch | cmp -s "$(git rev-parse --git-path primary-status-baseline)" -'
      COMMIT_PREFIX = "git commit "
      READBACK = '"$FORGEJO_AUTH" rest --token-file "$FORGEJO_TOKEN_FILE" --method GET --url "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/pulls/<number>"'

      def validate(text: str) -> None:
          lines = [line.strip() for line in re.sub(r"\\\n\s*", "", text).splitlines()]
          assert lines.count(FETCH) == 1, "require exactly one fetch command"
          assert lines.count(WORKTREE) == 1, "require exact worktree-add command"
          assert lines.count(CAPTURE) == 1, "require exact administrative-git-path baseline capture"
          assert lines.count(COMPARE) == 2, "require exactly two executable baseline compares"
          assert lines.count(READBACK) == 1, "require exact authenticated PR readback"
          fetch = lines.index(FETCH)
          worktree = lines.index(WORKTREE)
          capture = lines.index(CAPTURE)
          compares = [index for index, line in enumerate(lines) if line == COMPARE]
          commit = next(index for index, line in enumerate(lines) if line.startswith(COMMIT_PREFIX))
          readback = lines.index(READBACK)
          assert fetch < worktree < capture < compares[0] < commit < readback < compares[1], "checkout gates are out of order"

      def self_test() -> None:
          fixture = "\n".join([FETCH, WORKTREE, CAPTURE, COMPARE, "git commit -m fix", READBACK, COMPARE])
          validate(fixture)
          lines = fixture.splitlines()
          for compare_index in (3, 6):
              for replacement in (None, "Verify the primary checkout is unchanged."):
                  mutant = lines.copy()
                  if replacement is None:
                      del mutant[compare_index]
                  else:
                      mutant[compare_index] = replacement
                  try:
                      validate("\n".join(mutant))
                  except (AssertionError, StopIteration):
                      pass
                  else:
                      raise AssertionError("compare-removal/prose mutant unexpectedly passed")
          for replacement in ("", READBACK.replace("--method GET", "--method POST"), "Read the PR back."):
              try:
                  validate(fixture.replace(READBACK, replacement))
              except AssertionError:
                  pass
              else:
                  raise AssertionError("readback-removal/mutation mutant unexpectedly passed")

      if sys.argv[1:] == ["--self-test"]:
          self_test()
      else:
          validate(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    '';
    ntfyRuntimeCheck = pkgs.writeText "check-hermes-ntfy-runtime.py" ''
      from gateway.platform_registry import platform_registry
      import hermes_state
      import hermes_state_holders
      import hermes_state_registry
      from hermes_cli.config import load_config
      from hermes_cli.plugins import discover_plugins, get_plugin_manager
      from hermes_cli.tools_config import _get_platform_tools

      discover_plugins(force=True)
      loaded = get_plugin_manager()._plugins.get("ntfy-platform")
      assert loaded is not None and loaded.enabled, "ntfy-platform plugin is not enabled"
      assert "ntfy" in {entry.name for entry in platform_registry.plugin_entries()}

      config = load_config()
      effective = set(_get_platform_tools(config, "ntfy"))
      cli_effective = set(_get_platform_tools(config, "cli"))
      assert effective == cli_effective, sorted(effective ^ cli_effective)
      required = {
          "browser",
          "code_execution",
          "computer_use",
          "delegation",
          "file",
          "homeassistant",
          "nixos",
          "pfsense",
          "playwright",
          "terminal",
          "unifi",
      }
      assert required <= effective, sorted(required - effective)
    '';
  in
    pkgs.runCommand "ai-portability" {} ''
      ${pkgs.python3}/bin/python3 ${../../.}/scripts/generate-ai-adapters.py --check
      ${pkgs.python3}/bin/python3 ${../../.}/scripts/merge-toml-settings.py --self-test
      alert_rca_skill=${../../.}/hermes/skills/homelab-agents/alert-rca/SKILL.md
      ${pkgs.python3}/bin/python3 ${rcaCheckoutSafetyCheck} --self-test
      ${pkgs.python3}/bin/python3 ${rcaCheckoutSafetyCheck} "$alert_rca_skill"
      ${pkgs.yq-go}/bin/yq -o=json \
        ${../../.}/hermes/config/default/config.yaml \
        | ${pkgs.jq}/bin/jq -e \
          '.plugins.enabled | contains(["platforms/ntfy"])' >/dev/null
      ${pkgs.yq-go}/bin/yq -o=json \
        ${../../.}/hermes/config/default/config.yaml \
        | ${pkgs.jq}/bin/jq -e \
          '.platform_toolsets.ntfy == .platform_toolsets.cli' >/dev/null
      ${pkgs.yq-go}/bin/yq -o=json \
        ${../../.}/hermes/config/default/config.yaml \
        | ${pkgs.jq}/bin/jq -e \
          '.known_plugin_toolsets.ntfy == .known_plugin_toolsets.cli' >/dev/null
      hermes_python="$(${pkgs.gnugrep}/bin/grep '^export HERMES_PYTHON=' \
        ${pkgs.hermes-agent}/bin/hermes | ${pkgs.coreutils}/bin/cut -d"'" -f2)"
      test -x "$hermes_python"
      export HERMES_HOME="$TMPDIR/hermes-home"
      export HERMES_BUNDLED_PLUGINS=${pkgs.hermes-agent}/share/hermes-agent/plugins
      mkdir -p "$HERMES_HOME"
      cp ${../../.}/hermes/config/default/config.yaml "$HERMES_HOME/config.yaml"
      ${pkgs.hermes-agent}/bin/hermes sessions list --limit 1
      PYTHONPATH=${pkgs.hermes-agent.hermesStateStoreModules}/${pkgs.python312.sitePackages} \
        "$hermes_python" ${ntfyRuntimeCheck}
      touch $out
    '';
in {
  inherit
    nixpkgsFollowsCheck
    aiPortabilityCheck
    ;
}
