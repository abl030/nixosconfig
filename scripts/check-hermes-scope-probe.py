#!/usr/bin/env python3
"""Exercise Hermes's real systemd probe on the target NixOS user bus.

Run with the packaged Hermes interpreter, outside the Nix build sandbox.
"""
import logging
from tools import process_registry

logging.basicConfig(level=logging.DEBUG)
assert process_registry._systemd_run_user_scope_available(), "Hermes cannot dispatch cron workers"
print("PASS: Hermes created and completed its real transient-scope probe")
