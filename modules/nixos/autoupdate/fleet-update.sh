#!/usr/bin/env bash
set -Eeuo pipefail

TAG="fleet-update"

STATE_DIR="${FLEET_UPDATE_STATE_DIR:-/var/lib/fleet-update}"
REPO_DIR="${FLEET_UPDATE_REPO_DIR:-$STATE_DIR/repo}"
ALLOWED_SIGNERS_FILE="${FLEET_UPDATE_ALLOWED_SIGNERS_FILE:-/etc/fleet-update/allowed_signers}"
LAST_VERIFIED_REV_FILE="${FLEET_UPDATE_LAST_VERIFIED_REV_FILE:-$STATE_DIR/last-verified-rev}"
LAST_SOURCE_CONTACT_FILE="${FLEET_UPDATE_LAST_SOURCE_CONTACT_FILE:-$STATE_DIR/last-source-contact}"
LAST_VERIFIED_FRESHNESS_FILE="${FLEET_UPDATE_LAST_VERIFIED_FRESHNESS_FILE:-$STATE_DIR/last-verified-freshness}"
HIGHEST_SEEN_HEARTBEAT_FILE="${FLEET_UPDATE_HIGHEST_SEEN_HEARTBEAT_FILE:-$STATE_DIR/highest-seen-heartbeat}"
ORIGINS_RAW="${FLEET_UPDATE_ORIGINS:-github=https://github.com/abl030/nixosconfig.git}"
WRITE_ROOT="${FLEET_UPDATE_WRITE_ROOT:-github}"
BRANCH="${FLEET_UPDATE_BRANCH:-master}"
FLEET_HOSTNAME="${FLEET_UPDATE_HOSTNAME:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)}"
HEARTBEAT_FILE="${FLEET_UPDATE_HEARTBEAT_FILE:-fleet/freshness.json}"
BOT_PRINCIPAL="${FLEET_UPDATE_BOT_PRINCIPAL:-nix bot <acme@ablz.au>}"
FRESHNESS_MAX_AGE_SECONDS="${FLEET_UPDATE_FRESHNESS_MAX_AGE_SECONDS:-108000}"
REBUILD_BIN="${FLEET_UPDATE_REBUILD_BIN:-nixos-rebuild}"
REBUILD_FLAGS="${FLEET_UPDATE_REBUILD_FLAGS:---no-write-lock-file -L --option accept-flake-config true}"
NIX_BIN="${FLEET_UPDATE_NIX_BIN:-nix}"
NIX_FETCH_CACHE_DIR="${FLEET_UPDATE_NIX_FETCH_CACHE_DIR:-/root/.cache/nix}"
FAILURE_LOG="${FLEET_UPDATE_FAILURE_LOG:-/var/lib/nixos-upgrade/last-failure.log}"
SUCCESS_TIMESTAMP_FILE="${FLEET_UPDATE_SUCCESS_TIMESTAMP_FILE:-/var/lib/nixos-upgrade/last-success-timestamp}"
SKIP_PREFLIGHT="${FLEET_UPDATE_SKIP_PREFLIGHT:-0}"
NO_SWITCH="${FLEET_UPDATE_NO_SWITCH:-0}"
CURRENT_REV_OVERRIDE="${FLEET_UPDATE_CURRENT_REV:-}"
NOW_OVERRIDE="${FLEET_UPDATE_NOW:-}"

REQUESTED_REV=""
ACCEPT_NEW_ROOT=""
ALLOW_NON_MASTER=0
PROBE_ORIGINS=0
ANCHOR_FROM_ACCEPT=0

declare -a ORIGIN_NAMES=()
declare -a ORIGIN_URLS=()
declare -a CANDIDATE_NAMES=()
declare -a CANDIDATE_REFS=()
declare -a CANDIDATE_SHAS=()

log() { printf '[%s] %s\n' "$TAG" "$*" >&2; }

usage() {
    cat <<EOF
Usage: fleet-update [--rev SHA] [--accept-new-root SHA] [--branch master]
                    [--allow-non-master] [--probe-origins] [--dry-run]

Verifies a configured branch against /etc/fleet-update/allowed_signers before
running nixos-rebuild from the verified local clone and exact commit SHA.
EOF
}

die_usage() {
    log "usage error: $*"
    usage >&2
    exit 2
}

fail() {
    log "ERROR: $*"
    exit 1
}

tamper() {
    log "TAMPER: $*"
    exit 1
}

skip_plumbing() {
    log "SKIP: $*"
    exit 0
}

is_truthy() {
    case "$1" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_sha() {
    [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
}

now_epoch() {
    if [ -n "$NOW_OVERRIDE" ]; then
        printf '%s\n' "$NOW_OVERRIDE"
    else
        date -u +%s
    fi
}

epoch_iso() {
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --rev)
                [ "$#" -ge 2 ] || die_usage "--rev requires a SHA"
                REQUESTED_REV="$2"
                shift 2
                ;;
            --accept-new-root)
                [ "$#" -ge 2 ] || die_usage "--accept-new-root requires a SHA"
                ACCEPT_NEW_ROOT="$2"
                shift 2
                ;;
            --branch)
                [ "$#" -ge 2 ] || die_usage "--branch requires a branch name"
                BRANCH="$2"
                shift 2
                ;;
            --allow-non-master)
                ALLOW_NON_MASTER=1
                shift
                ;;
            --probe-origins)
                PROBE_ORIGINS=1
                shift
                ;;
            --dry-run)
                NO_SWITCH=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die_usage "unknown argument: $1"
                ;;
        esac
    done

    if [ "$BRANCH" != "master" ] && [ "$ALLOW_NON_MASTER" -ne 1 ]; then
        die_usage "--branch $BRANCH refused; use --allow-non-master for break-glass only"
    fi
    if [ -n "$REQUESTED_REV" ] && ! is_sha "$REQUESTED_REV"; then
        die_usage "--rev must be a full 40-character commit SHA"
    fi
    if [ -n "$ACCEPT_NEW_ROOT" ] && ! is_sha "$ACCEPT_NEW_ROOT"; then
        die_usage "--accept-new-root must be a full 40-character commit SHA"
    fi
}

parse_origins() {
    local entry name url
    local -a entries=()

    # shellcheck disable=SC2206 # ORIGINS_RAW is a controlled space-separated name=url list.
    entries=($ORIGINS_RAW)
    [ "${#entries[@]}" -gt 0 ] || die_usage "no fetch origins configured"

    for entry in "${entries[@]}"; do
        [[ "$entry" == *=* ]] || die_usage "origin entry must be name=url: $entry"
        name="${entry%%=*}"
        url="${entry#*=}"
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die_usage "invalid origin name: $name"
        [ -n "$url" ] || die_usage "origin $name has an empty URL"
        ORIGIN_NAMES+=("$name")
        ORIGIN_URLS+=("$url")
    done
}

origin_url() {
    local wanted="$1"
    local i
    for i in "${!ORIGIN_NAMES[@]}"; do
        if [ "${ORIGIN_NAMES[$i]}" = "$wanted" ]; then
            printf '%s\n' "${ORIGIN_URLS[$i]}"
            return 0
        fi
    done
    return 1
}

probe_origins() {
    local i name url any=0
    for i in "${!ORIGIN_NAMES[@]}"; do
        name="${ORIGIN_NAMES[$i]}"
        url="${ORIGIN_URLS[$i]}"
        if git ls-remote --exit-code --heads "$url" "$BRANCH" >/dev/null 2>&1; then
            log "origin reachable: $name ($BRANCH)"
            any=1
        else
            log "origin not reachable: $name ($BRANCH)"
        fi
    done
    [ "$any" -eq 1 ]
}

clone_repo() {
    local i name url
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true

    if [ -e "$REPO_DIR" ] && [ ! -d "$REPO_DIR/.git" ]; then
        fail "$REPO_DIR exists but is not a git checkout"
    fi
    if [ -d "$REPO_DIR/.git" ]; then
        return 0
    fi

    for i in "${!ORIGIN_NAMES[@]}"; do
        name="${ORIGIN_NAMES[$i]}"
        url="${ORIGIN_URLS[$i]}"
        log "initialising local clone from $name"
        if git clone -q --single-branch --branch "$BRANCH" "$url" "$REPO_DIR"; then
            return 0
        fi
        log "clone from $name failed"
    done

    skip_plumbing "no configured origin could initialise $REPO_DIR"
}

configure_remotes() {
    local i name url
    for i in "${!ORIGIN_NAMES[@]}"; do
        name="${ORIGIN_NAMES[$i]}"
        url="${ORIGIN_URLS[$i]}"
        if git -C "$REPO_DIR" remote get-url "$name" >/dev/null 2>&1; then
            git -C "$REPO_DIR" remote set-url "$name" "$url"
        else
            git -C "$REPO_DIR" remote add "$name" "$url"
        fi
    done
}

fetch_origins() {
    local i name ref sha any=0
    CANDIDATE_NAMES=()
    CANDIDATE_REFS=()
    CANDIDATE_SHAS=()

    for i in "${!ORIGIN_NAMES[@]}"; do
        name="${ORIGIN_NAMES[$i]}"
        ref="refs/remotes/$name/$BRANCH"
        log "fetching $name/$BRANCH"
        if git -C "$REPO_DIR" fetch --prune "$name" "+refs/heads/$BRANCH:$ref"; then
            sha="$(git -C "$REPO_DIR" rev-parse --verify "$ref^{commit}")"
            CANDIDATE_NAMES+=("$name")
            CANDIDATE_REFS+=("$ref")
            CANDIDATE_SHAS+=("$sha")
            log "fetched $name/$BRANCH at $sha"
            any=1
        else
            log "fetch failed for $name/$BRANCH"
        fi
    done

    [ "$any" -eq 1 ] || skip_plumbing "no configured origin was fetchable"
}

verify_commit() {
    local rev="$1"
    local output

    if [ ! -r "$ALLOWED_SIGNERS_FILE" ]; then
        fail "allowed_signers is missing or unreadable: $ALLOWED_SIGNERS_FILE"
    fi

    if ! output="$(git -C "$REPO_DIR" -c "gpg.ssh.allowedSignersFile=$ALLOWED_SIGNERS_FILE" verify-commit "$rev" 2>&1)"; then
        log "commit $rev failed SSH signature verification"
        printf '%s\n' "$output"
        return 1
    fi
}

verify_candidate_tips() {
    local i
    for i in "${!CANDIDATE_SHAS[@]}"; do
        verify_commit "${CANDIDATE_SHAS[$i]}" || tamper "${CANDIDATE_NAMES[$i]}/$BRANCH tip is not signed by an allowed key"
    done
}

write_json_marker() {
    local path="$1"
    local tmp

    mkdir -p "$(dirname "$path")"
    tmp="$path.tmp"
    cat >"$tmp"
    mv "$tmp" "$path"
}

write_source_contact() {
    local now
    now="$(now_epoch)"
    jq -n \
        --argjson epoch "$now" \
        --arg timestamp "$(epoch_iso "$now")" \
        --arg host "$FLEET_HOSTNAME" \
        --arg branch "$BRANCH" \
        --argjson origins "${#CANDIDATE_SHAS[@]}" \
        '{epoch: $epoch, timestamp: $timestamp, host: $host, branch: $branch, verified_origins: $origins}' \
        | write_json_marker "$LAST_SOURCE_CONTACT_FILE"
}

commit_signature_status() {
    local rev="$1"
    git -C "$REPO_DIR" \
        -c "gpg.ssh.allowedSignersFile=$ALLOWED_SIGNERS_FILE" \
        log -1 --format='%G?%n%GS' "$rev"
}

verify_commit_principal() {
    local rev="$1"
    local expected="$2"
    local record status signer

    verify_commit "$rev" || return 1
    record="$(commit_signature_status "$rev")"
    status="$(printf '%s\n' "$record" | sed -n '1p')"
    signer="$(printf '%s\n' "$record" | sed -n '2p')"
    if [ "$status" != "G" ] || [ "$signer" != "$expected" ]; then
        log "commit $rev was signed by '$signer' (status=$status), expected '$expected'"
        return 1
    fi
}

read_highest_seen_heartbeat() {
    local value=0
    if [ -s "$HIGHEST_SEEN_HEARTBEAT_FILE" ]; then
        value="$(tr -d '[:space:]' <"$HIGHEST_SEEN_HEARTBEAT_FILE")"
    fi
    case "$value" in
        ''|*[!0-9]*) value=0 ;;
    esac
    printf '%s\n' "$value"
}

write_highest_seen_heartbeat() {
    local epoch="$1"
    local tmp

    mkdir -p "$(dirname "$HIGHEST_SEEN_HEARTBEAT_FILE")"
    tmp="$HIGHEST_SEEN_HEARTBEAT_FILE.tmp"
    printf '%s\n' "$epoch" >"$tmp"
    mv "$tmp" "$HIGHEST_SEEN_HEARTBEAT_FILE"
}

freshness_fail() {
    log "FLEET-FRESHNESS FAIL $*"
}

record_verified_freshness() {
    local target="$1"
    local heartbeat_commit heartbeat_json heartbeat_epoch heartbeat_timestamp heartbeat_status heartbeat_actor
    local highest_seen now age

    if ! git -C "$REPO_DIR" cat-file -e "$target:$HEARTBEAT_FILE" 2>/dev/null; then
        freshness_fail "missing $HEARTBEAT_FILE at target=$target"
        return 0
    fi

    heartbeat_commit="$(git -C "$REPO_DIR" rev-list -1 "$target" -- "$HEARTBEAT_FILE" || true)"
    if [ -z "$heartbeat_commit" ]; then
        freshness_fail "no commit found for $HEARTBEAT_FILE at target=$target"
        return 0
    fi

    if ! verify_commit_principal "$heartbeat_commit" "$BOT_PRINCIPAL"; then
        freshness_fail "$HEARTBEAT_FILE last changed by untrusted commit=$heartbeat_commit target=$target"
        return 0
    fi

    heartbeat_json="$(git -C "$REPO_DIR" show "$target:$HEARTBEAT_FILE" 2>/dev/null || true)"
    if ! heartbeat_epoch="$(printf '%s\n' "$heartbeat_json" | jq -er '.epoch | numbers | floor' 2>/dev/null)"; then
        freshness_fail "malformed heartbeat epoch in $HEARTBEAT_FILE target=$target"
        return 0
    fi
    heartbeat_timestamp="$(printf '%s\n' "$heartbeat_json" | jq -r '.timestamp // ""' 2>/dev/null || true)"
    heartbeat_status="$(printf '%s\n' "$heartbeat_json" | jq -r '.status // ""' 2>/dev/null || true)"
    heartbeat_actor="$(printf '%s\n' "$heartbeat_json" | jq -r '.actor // ""' 2>/dev/null || true)"

    if [ "$heartbeat_status" != "green" ]; then
        freshness_fail "heartbeat status is '$heartbeat_status', not green, target=$target heartbeat_commit=$heartbeat_commit"
        return 0
    fi

    highest_seen="$(read_highest_seen_heartbeat)"
    if [ "$heartbeat_epoch" -lt "$highest_seen" ]; then
        freshness_fail "heartbeat moved backward target=$target heartbeat_epoch=$heartbeat_epoch highest_seen=$highest_seen"
        return 0
    fi

    now="$(now_epoch)"
    age=$((now - heartbeat_epoch))
    if [ "$age" -gt "$FRESHNESS_MAX_AGE_SECONDS" ]; then
        freshness_fail "heartbeat stale target=$target heartbeat_epoch=$heartbeat_epoch age_seconds=$age max_age_seconds=$FRESHNESS_MAX_AGE_SECONDS"
        return 0
    fi

    if [ "$heartbeat_epoch" -gt "$highest_seen" ]; then
        write_highest_seen_heartbeat "$heartbeat_epoch"
    fi

    jq -n \
        --argjson observed_epoch "$now" \
        --arg observed_timestamp "$(epoch_iso "$now")" \
        --arg host "$FLEET_HOSTNAME" \
        --arg target "$target" \
        --arg heartbeat_commit "$heartbeat_commit" \
        --argjson heartbeat_epoch "$heartbeat_epoch" \
        --arg heartbeat_timestamp "$heartbeat_timestamp" \
        --arg heartbeat_actor "$heartbeat_actor" \
        --arg heartbeat_status "$heartbeat_status" \
        '{observed_epoch: $observed_epoch, observed_timestamp: $observed_timestamp, host: $host, target: $target, heartbeat_commit: $heartbeat_commit, heartbeat_epoch: $heartbeat_epoch, heartbeat_timestamp: $heartbeat_timestamp, heartbeat_actor: $heartbeat_actor, heartbeat_status: $heartbeat_status}' \
        | write_json_marker "$LAST_VERIFIED_FRESHNESS_FILE"
    log "freshness heartbeat verified at epoch=$heartbeat_epoch target=$target"
}

verify_commit_range() {
    local base="$1"
    local target="$2"
    local rev

    while IFS= read -r rev; do
        [ -n "$rev" ] || continue
        verify_commit "$rev" || tamper "deployment range contains an untrusted commit: $rev"
    done < <(git -C "$REPO_DIR" rev-list "$base..$target")
}

target_reachable_from_candidates() {
    local target="$1"
    local sha
    for sha in "${CANDIDATE_SHAS[@]}"; do
        if git -C "$REPO_DIR" merge-base --is-ancestor "$target" "$sha"; then
            return 0
        fi
    done
    return 1
}

select_candidate_target() {
    local target sha name
    local i

    if [ -n "$REQUESTED_REV" ]; then
        git -C "$REPO_DIR" cat-file -e "$REQUESTED_REV^{commit}" 2>/dev/null || tamper "requested rev is not present after fetch: $REQUESTED_REV"
        target_reachable_from_candidates "$REQUESTED_REV" || tamper "requested rev is not contained in any configured $BRANCH branch"
        printf '%s\n' "$REQUESTED_REV"
        return 0
    fi

    target="${CANDIDATE_SHAS[0]}"
    for i in "${!CANDIDATE_SHAS[@]}"; do
        sha="${CANDIDATE_SHAS[$i]}"
        name="${CANDIDATE_NAMES[$i]}"
        if [ "$sha" = "$target" ]; then
            continue
        elif git -C "$REPO_DIR" merge-base --is-ancestor "$target" "$sha"; then
            target="$sha"
        elif git -C "$REPO_DIR" merge-base --is-ancestor "$sha" "$target"; then
            :
        else
            tamper "configured origins diverged: selected $target but $name has $sha"
        fi
    done

    printf '%s\n' "$target"
}

confirm_write_root_contains_target() {
    local target="$1"
    local ref="refs/remotes/$WRITE_ROOT/$BRANCH"

    if ! origin_url "$WRITE_ROOT" >/dev/null; then
        fail "write root '$WRITE_ROOT' is not listed in configured origins"
    fi
    if ! git -C "$REPO_DIR" show-ref --verify --quiet "$ref"; then
        skip_plumbing "write root $WRITE_ROOT/$BRANCH was not fetched; refusing to deploy from fallback alone"
    fi
    if ! git -C "$REPO_DIR" merge-base --is-ancestor "$target" "$ref"; then
        tamper "target $target is not contained in write root $WRITE_ROOT/$BRANCH"
    fi
}

read_running_revision() {
    if [ -n "$CURRENT_REV_OVERRIDE" ]; then
        printf '%s\n' "$CURRENT_REV_OVERRIDE"
        return 0
    fi
    if command -v nixos-version >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        nixos-version --json 2>/dev/null | jq -r '.configurationRevision // empty' 2>/dev/null || true
    fi
}

read_anchor() {
    local rev

    if [ -n "$ACCEPT_NEW_ROOT" ]; then
        git -C "$REPO_DIR" cat-file -e "$ACCEPT_NEW_ROOT^{commit}" 2>/dev/null || tamper "accepted root is not present after fetch: $ACCEPT_NEW_ROOT"
        verify_commit "$ACCEPT_NEW_ROOT" || tamper "accepted root is not signed by an allowed key"
        ANCHOR_FROM_ACCEPT=1
        printf '%s\n' "$ACCEPT_NEW_ROOT"
        return 0
    fi

    rev="$(read_running_revision | tr -d '[:space:]')"
    if is_sha "$rev"; then
        printf '%s\n' "$rev"
        return 0
    fi

    if [ -s "$LAST_VERIFIED_REV_FILE" ]; then
        rev="$(tr -d '[:space:]' <"$LAST_VERIFIED_REV_FILE")"
        is_sha "$rev" || fail "last verified revision is not a commit SHA: $LAST_VERIFIED_REV_FILE"
        printf '%s\n' "$rev"
        return 0
    fi

    tamper "no deployment anchor found; use --accept-new-root <expected-sha> after out-of-band verification"
}

classify_target() {
    local anchor="$1"
    local target="$2"

    git -C "$REPO_DIR" cat-file -e "$anchor^{commit}" 2>/dev/null || tamper "deployment anchor is not present in fetched history: $anchor"
    git -C "$REPO_DIR" cat-file -e "$target^{commit}" 2>/dev/null || tamper "target is not present in fetched history: $target"

    verify_commit "$anchor" || tamper "deployment anchor is not signed by an allowed key: $anchor"

    if [ "$target" = "$anchor" ] && [ "$ANCHOR_FROM_ACCEPT" -eq 0 ]; then
        verify_commit "$target" || tamper "current target is not signed by an allowed key: $target"
        log "already on verified target $target"
        printf 'noop\n'
    elif git -C "$REPO_DIR" merge-base --is-ancestor "$target" "$anchor" && [ "$ANCHOR_FROM_ACCEPT" -eq 0 ]; then
        verify_commit "$target" || tamper "stale target is not signed by an allowed key: $target"
        log "target $target is older than current anchor $anchor; skipping"
        printf 'skip\n'
    elif git -C "$REPO_DIR" merge-base --is-ancestor "$anchor" "$target"; then
        verify_commit_range "$anchor" "$target"
        printf 'deploy\n'
    else
        tamper "target $target diverges from deployment anchor $anchor"
    fi
}

flake_ref() {
    local target="$1"
    printf 'git+file://%s?ref=%s&rev=%s#%s' "$REPO_DIR" "$BRANCH" "$target" "$FLEET_HOSTNAME"
}

is_plumbing_failure_log() {
    local log_file="$1"
    grep -Eiq 'HTTP error (401|403|5[0-9][0-9])|failed to insert entry|timed out|timeout|Could not resolve host|Network is unreachable|Connection reset|temporary failure' "$log_file"
}

metadata_preflight() {
    local ref="$1"
    local log_file

    is_truthy "$SKIP_PREFLIGHT" && return 0

    log_file="$(mktemp)"
    if "$NIX_BIN" flake metadata "$ref" --no-write-lock-file --option accept-flake-config true >"$log_file" 2>&1; then
        rm -f "$log_file"
        return 0
    fi

    if is_plumbing_failure_log "$log_file"; then
        log "metadata preflight hit fetch plumbing; clearing $NIX_FETCH_CACHE_DIR and retrying once"
        if [ -n "$NIX_FETCH_CACHE_DIR" ] && [ -d "$NIX_FETCH_CACHE_DIR" ]; then
            rm -rf "$NIX_FETCH_CACHE_DIR"
        fi
        if "$NIX_BIN" flake metadata "$ref" --no-write-lock-file --option accept-flake-config true >"$log_file" 2>&1; then
            rm -f "$log_file"
            return 0
        fi
        if is_plumbing_failure_log "$log_file"; then
            cat "$log_file"
            rm -f "$log_file"
            skip_plumbing "metadata preflight still has fetch plumbing; leaving current generation running"
        fi
    fi

    cat "$log_file"
    rm -f "$log_file"
    fail "metadata preflight failed for verified target"
}

write_success_anchor() {
    local target="$1"
    local tmp

    mkdir -p "$(dirname "$LAST_VERIFIED_REV_FILE")"
    tmp="$LAST_VERIFIED_REV_FILE.tmp"
    printf '%s\n' "$target" >"$tmp"
    mv "$tmp" "$LAST_VERIFIED_REV_FILE"

    mkdir -p "$(dirname "$SUCCESS_TIMESTAMP_FILE")"
    date +%s >"$SUCCESS_TIMESTAMP_FILE"
}

run_switch() {
    local target="$1"
    local ref
    local log_file
    local status
    local -a rebuild_flags=()

    ref="$(flake_ref "$target")"
    git -C "$REPO_DIR" checkout -q --detach "$target"
    git -C "$REPO_DIR" reset --hard -q "$target"
    git -C "$REPO_DIR" clean -fd -q

    metadata_preflight "$ref"

    if is_truthy "$NO_SWITCH"; then
        log "dry-run verified $target for $FLEET_HOSTNAME; switch skipped"
        return 0
    fi

    # shellcheck disable=SC2206 # REBUILD_FLAGS is a controlled space-separated flag list from the Nix module.
    rebuild_flags=($REBUILD_FLAGS)
    log "switching $FLEET_HOSTNAME to $target"
    log_file="$(mktemp)"
    set +e
    "$REBUILD_BIN" switch --flake "$ref" "${rebuild_flags[@]}" >"$log_file" 2>&1
    status=$?
    set -e
    cat "$log_file"

    if [ "$status" -eq 0 ]; then
        rm -f "$log_file"
        write_success_anchor "$target"
        log "switch succeeded; anchor advanced to $target"
        return 0
    fi

    mkdir -p "$(dirname "$FAILURE_LOG")"
    install -m 0644 "$log_file" "$FAILURE_LOG" || true
    rm -f "$log_file"
    fail "nixos-rebuild failed for verified target $target"
}

main() {
    local target anchor action

    parse_args "$@"
    parse_origins

    if [ "$PROBE_ORIGINS" -eq 1 ]; then
        probe_origins
        exit $?
    fi

    clone_repo
    configure_remotes
    fetch_origins
    verify_candidate_tips
    write_source_contact

    target="$(select_candidate_target)"
    confirm_write_root_contains_target "$target"

    anchor="$(read_anchor)"
    action="$(classify_target "$anchor" "$target")"
    case "$action" in
        deploy)
            record_verified_freshness "$target"
            run_switch "$target"
            ;;
        noop)
            record_verified_freshness "$target"
            exit 0
            ;;
        skip) exit 0 ;;
        *) fail "internal classification error: $action" ;;
    esac
}

main "$@"
