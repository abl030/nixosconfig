#!/usr/bin/env python3
"""Selective behavioral mutants must fail their targeted regression tests."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).parents[2]
helper = Path(os.environ.get("FORGEJO_AUTH_HELPER", ROOT / "scripts/forgejo-auth.sh"))
behavior = Path(os.environ.get("FORGEJO_AUTH_BEHAVIOR_TEST", Path(__file__).with_name("test_forgejo_auth.py")))
real = Path(os.environ.get("FORGEJO_AUTH_REAL_TEST", Path(__file__).with_name("test_forgejo_auth_real.py")))
source = helper.read_text()
ordering = source.replace('    read_token "$token_file"\n    sanitize_debug_environment', '    sanitize_debug_environment', 1).replace('    [[ -n "$fetch_output" ]]', '    read_token "$token_file"\n    [[ -n "$fetch_output" ]]', 1)
mutants = {
    "rest-read-before-url": (source.replace('    # URL/method policy is checked before the secret file is opened.\n    read_token "$token_file"', '    # mutant: credential already opened').replace('    safe_api_url "$url"', '    read_token "$token_file"\n    safe_api_url "$url"'), behavior, "rest_wrong_url"),
    "read-before-comparison": (ordering, behavior, "wrong_or_multiple_remote"),
    "curlrc-enabled": (source.replace("curl -q --silent", "curl --silent"), real, "real_curlrc"),
    "token-in-argv": (source.replace('    exec git "${git_args[@]}"', '    exec git -c "review.leak=$FORGEJO_TOKEN" "${git_args[@]}"'), behavior, "40_byte_eof"),
    "debug-trap-retained": (source.replace("trap - DEBUG RETURN ERR EXIT", ":"), behavior, "startup_debug_trap"),
    "config-trace2-enabled": (source.replace("    export GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0", "    :"), real, "global_and_system_trace2"),
    "config-rewrite-retained": (source.replace("    normalize_git_environment\n", "    sanitize_debug_environment\n"), real, "inherited_rewrites"),
}
with tempfile.TemporaryDirectory(prefix="forgejo-mutants-") as temp:
    for name, (text, suite, selector) in mutants.items():
        assert text != source, name + " did not mutate source"
        path = Path(temp) / (name + ".sh")
        path.write_text(text)
        path.chmod(0o700)
        result = subprocess.run([sys.executable, str(suite), "-k", selector], env={**os.environ, "FORGEJO_AUTH_HELPER": str(path), "PYTHONDONTWRITEBYTECODE": "1"}, text=True, capture_output=True, timeout=30)
        # A harness/import/syntax error is not a killed behavioral mutant.
        assert result.returncode != 0 and "FAIL:" in result.stderr and "ERROR:" not in result.stderr, (name, result.stdout, result.stderr)
        print(name + ": KILLED by assertion (" + selector + ")")
print(f"qualified {len(mutants)} selective behavioral mutants")
