#!/usr/bin/env sh
# TouchModTime - NZBGet post-processing script (with extra logging)
# Sets modification time (mtime) of downloaded files to "now".

# NZBGet exit codes
POSTPROCESS_SUCCESS=93
POSTPROCESS_ERROR=94
POSTPROCESS_NONE=95

log() { printf '%s\n' "$*"; }
info() { log "[INFO] $*"; }
warn() { log "[WARNING] $*"; }
err() { log "[ERROR] $*"; }

info "TouchModTime starting"
info "NZBGet version: ${NZBOP_VERSION:-unknown}"
info "NZB name: ${NZBPP_NZBNAME:-unknown}"
info "Category: ${NZBPP_CATEGORY:-unset}"
info "TOTALSTATUS=${NZBPP_TOTALSTATUS:-unset}"
info "FINALDIR=${NZBPP_FINALDIR:-unset}"
info "DIRECTORY=${NZBPP_DIRECTORY:-unset}"

# 1) Only run after successful download/unpack
if [ "${NZBPP_TOTALSTATUS:-}" != "SUCCESS" ]; then
    info "Status is '${NZBPP_TOTALSTATUS:-UNKNOWN}', skipping."
    exit $POSTPROCESS_NONE
fi

# 2) Decide target dir
TARGET_DIR="${NZBPP_FINALDIR:-${NZBPP_DIRECTORY:-}}"
info "Chosen TARGET_DIR='${TARGET_DIR}'"

if [ -z "$TARGET_DIR" ]; then
    err "Neither NZBPP_FINALDIR nor NZBPP_DIRECTORY is set. Aborting."
    exit $POSTPROCESS_ERROR
fi

if [ ! -d "$TARGET_DIR" ]; then
    err "Target directory does not exist: $TARGET_DIR"
    exit $POSTPROCESS_ERROR
fi

# 3) Count files before touching (for visibility)
total_before=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
info "Found ${total_before:-0} files under TARGET_DIR before touching."

# 4) Touch all regular files recursively
# Use -print0 for safety with weird filenames.
# We allow partial failures but warn.
failed=0
if [ "${total_before:-0}" -gt 0 ]; then
    info "Touching files..."
    find "$TARGET_DIR" -type f -print0 |
    xargs -0 -I{} sh -c '
      if touch -m -- "{}"; then
        :
      else
        echo "[WARNING] Failed to touch: {}" >&2
        exit 1
      fi
    ' || failed=$?
else
    info "Nothing to touch."
fi

# 5) Bump directory mtime as a nudge
if touch -m -- "$TARGET_DIR" 2>/dev/null; then
    info "Bumped directory mtime: $TARGET_DIR"
fi

# 6) Summary
if [ "$failed" -eq 0 ]; then
    info "TouchModTime complete: touched $total_before file(s)."
    exit $POSTPROCESS_SUCCESS
else
    warn "TouchModTime finished with warnings (some files failed to touch)."
    info "Attempted to touch $total_before file(s). Check warnings above."
    exit $POSTPROCESS_SUCCESS # still report SUCCESS to not poison NZB status
fi
