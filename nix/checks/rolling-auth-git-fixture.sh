#!/usr/bin/env bash
# Signing-check-only transport adapter. Production policy still sees and checks
# HTTPS URLs; only the final fixture transport maps to a disposable bare repo.
# All object transfer, signatures, range/replay checks and ref updates use Git.
set -euo pipefail
: "${FIXTURE_REAL_GIT:?}"
transport=""
for arg in "$@"; do
    case "$arg" in clone|fetch|push|ls-remote) transport="$arg" ;; esac
done
if [ -n "$transport" ] && [ -n "${FIXTURE_REMOTE:-}" ]; then
    if [ "$transport" = push ] || [ "$transport" = ls-remote ]; then
        printf -v dummy '%040d' 0
        [ "${GIT_CONFIG_VALUE_0:-}" = "Authorization: token $dummy" ] || {
            printf 'signing fixture: authenticated transport missing dummy credential\n' >&2
            exit 98
        }
    fi
    exec "$FIXTURE_REAL_GIT" \
        -c "url.file://$FIXTURE_REMOTE.insteadOf=https://git.ablz.au/abl030/nixosconfig.git" "$@"
fi
exec "$FIXTURE_REAL_GIT" "$@"
