"""Run one isolated Hermes analysis with an asserted empty tool surface."""

from __future__ import annotations

import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


def main() -> int:
    prompt = sys.stdin.read()
    if not prompt.strip():
        print("report agent received an empty prompt", file=sys.stderr)
        return 2

    import run_agent
    import hermes_cli.mcp_startup as mcp_startup
    from hermes_cli.oneshot import _run_agent

    original_agent = run_agent.AIAgent

    class ReportAgent(original_agent):
        @property
        def _platform_hint_overrides(self) -> dict[str, object]:
            return {}

        @_platform_hint_overrides.setter
        def _platform_hint_overrides(self, value: object) -> None:
            # Mutable config.yaml platform hints are not admitted here.
            return None

        def __init__(self, *args: object, **kwargs: object) -> None:
            kwargs["enabled_toolsets"] = []
            kwargs["platform"] = None
            kwargs["skip_context_files"] = True
            kwargs["skip_memory"] = True
            super().__init__(*args, **kwargs)
            if self.tools:
                raise RuntimeError(
                    "report agent isolation failed: tools were loaded"
                )
            if self._platform_hint_overrides:
                raise RuntimeError(
                    "report agent isolation failed: platform hints loaded"
                )

    run_agent.AIAgent = ReportAgent
    original_environment_hints = run_agent.build_environment_hints
    run_agent.build_environment_hints = lambda: ""
    original_mcp_startup = (
        mcp_startup.ensure_mcp_discovery_before_agent_build
    )
    mcp_startup.ensure_mcp_discovery_before_agent_build = (
        lambda **kwargs: None
    )
    try:
        with Path("/dev/null").open("w") as devnull:
            with redirect_stdout(devnull), redirect_stderr(devnull):
                response, result = _run_agent(
                    prompt,
                    toolsets=[],
                    use_config_toolsets=False,
                )
    finally:
        run_agent.build_environment_hints = original_environment_hints
        mcp_startup.ensure_mcp_discovery_before_agent_build = (
            original_mcp_startup
        )
        run_agent.AIAgent = original_agent

    if result.get("failed") or result.get("partial"):
        print("report agent did not complete", file=sys.stderr)
        return 1
    if not response.strip():
        print("report agent produced no response", file=sys.stderr)
        return 1
    print(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
