#!/usr/bin/env -S bash -p
# Trace-safe authentication boundary for Forgejo Git pushes and REST calls.
#
# Callers provide a token *file*, never the token. This command validates the
# destination before reading the file, then gives the short-lived child only the
# Git config environment or curl config it needs. Keep this executable small:
# consumers must not grow their own credential plumbing.
# -p ignores BASH_ENV and inherited shell functions/options at executable
# startup. Also clear ordinary debugging hooks when explicitly run with bash.
# This is not containment of a malicious same-UID executable or startup program.
trap - DEBUG RETURN ERR EXIT
set +x
set -Eeuo pipefail
unset BASH_XTRACEFD BASH_ENV ENV
export -n SHELLOPTS BASHOPTS

readonly FORGEJO_GIT_CONFIG_KEY="http.https://git.ablz.au.extraHeader"

fail() {
    printf 'forgejo-auth: %s\n' "$1" >&2
    exit 2
}

usage() {
    cat >&2 <<'EOF'
usage:
  forgejo-auth.sh validate-git-url --url URL
  forgejo-auth.sh git-push --repo DIR --remote NAME \
    --expected-fetch-url URL --expected-push-url URL \
    --token-file FILE --refspec REFSPEC [--force] [--quiet]
  forgejo-auth.sh git-ls-remote --repo DIR --remote NAME \
    --expected-fetch-url URL --expected-push-url URL --token-file FILE --ref REF
  forgejo-auth.sh rest --token-file FILE --method METHOD --url URL \
    [--body JSON | --body-stdin]
EOF
    exit 2
}

# A caller may have enabled shell tracing or Git/curl diagnostics. None of those
# settings may cross the credential boundary. The child receives no trace sink
# that could record its Authorization header.
sanitize_debug_environment() {
    local name
    for name in \
        GIT_TRACE \
        GIT_TRACE_PACKET \
        GIT_TRACE_PERFORMANCE \
        GIT_TRACE_SETUP \
        GIT_TRACE_SHALLOW \
        GIT_TRACE_CURL \
        GIT_TRACE2 \
        GIT_TRACE2_EVENT \
        GIT_TRACE2_PERF \
        GIT_TRACE2_BRIEF \
        GIT_TRACE2_CONFIG_PARAMS \
        GIT_TRACE2_ENV_VARS \
        GIT_TRACE2_PARENT \
        GIT_CURL_VERBOSE \
        CURL_VERBOSE \
        CURL_TRACE \
        CURL_TRACE_ASCII \
        CURL_TRACE_CONFIG; do
        unset "$name"
    done

    # Cover future Trace2 variables without allowing a caller-controlled name to
    # become shell syntax: ${!prefix@} expands only variable names.
    for name in ${!GIT_TRACE2@}; do
        unset "$name"
    done
    # Environment targets override system/global trace2.*Target configuration.
    export GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0
}

normalize_git_environment() {
    local name
    unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    for name in ${!GIT_CONFIG_KEY_@} ${!GIT_CONFIG_VALUE_@}; do
        unset "$name"
    done
    sanitize_debug_environment
}

safe_git_url() {
    [[ "$1" =~ ^https://git\.ablz\.au/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git$ ]]
}

safe_api_url() {
    local url="$1"
    [[ "$url" == https://git.ablz.au/api/v1/* ]] || return 1
    [[ "$url" != *'@'* ]] || return 1
    [[ "$url" != *'token='* ]] || return 1
    [[ "$url" != *'access_token='* ]] || return 1
    [[ "$url" != *$'\r'* ]] || return 1
    [[ "$url" != *$'\n'* ]] || return 1
}

read_token() {
    local token_file="$1"
    local file_bytes token_bytes

    [[ -f "$token_file" && -r "$token_file" ]] || fail "token file is missing or unreadable"
    file_bytes="$(wc -c <"$token_file")"
    FORGEJO_TOKEN="$(<"$token_file")"
    token_bytes="$(printf '%s' "$FORGEJO_TOKEN" | wc -c)"

    [[ -n "$FORGEJO_TOKEN" ]] || fail "token file is empty"
    # Command substitution strips LF only. Byte counts plus the fixed hex
    # grammar allow precisely EOF or one final LF, not NUL or multiline data.
    [[ "$FORGEJO_TOKEN" =~ ^[0-9a-fA-F]{40}$ ]] || fail "token file must contain a 40-byte hexadecimal credential"
    [[ "$file_bytes" -eq "$token_bytes" || "$file_bytes" -eq $((token_bytes + 1)) && "$file_bytes" -eq 41 && "$(tail -c 1 -- "$token_file" | od -An -tu1)" -eq 10 ]] \
        || fail "token file must end at EOF or one final LF"
    [[ "$FORGEJO_TOKEN" != *$'\r'* ]] || fail "token file contains a carriage return"
    [[ "$FORGEJO_TOKEN" != *$'\n'* ]] || fail "token file contains a newline"
    [[ "$FORGEJO_TOKEN" != *$'\t'* ]] || fail "token file contains a tab"
    [[ "$FORGEJO_TOKEN" != *' '* ]] || fail "token file contains a space"
    [[ "$FORGEJO_TOKEN" != *'"'* ]] || fail "token file contains a quote"
    case "$FORGEJO_TOKEN" in
        *\\*) fail "token file contains a backslash" ;;
    esac
}

remote_urls_match_exactly() {
    local repo="$1"
    local remote="$2"
    local expected_fetch="$3"
    local expected_push="$4"
    local fetch_output push_output raw_output kind
    local -a fetch_urls push_urls

    # Git get-url omits explicitly empty entries. They still make the authored
    # set ambiguous, so reject them before checking effective/re-written URLs.
    for kind in url pushurl; do
        if raw_output="$(git -C "$repo" config --get-all "remote.$remote.$kind" 2>/dev/null && printf '.')"; then
            raw_output="${raw_output%.}"
            [[ "$raw_output" != $'\n'* && "$raw_output" != *$'\n\n'* ]] \
                || fail "remote $remote contains an empty URL"
        fi
    done

    # Preserve trailing empty URLs; command substitution alone strips them.
    fetch_output="$(git -C "$repo" remote get-url --all "$remote" 2>/dev/null && printf '.')" \
        || fail "could not read the fetch URL for remote $remote"
    push_output="$(git -C "$repo" remote get-url --push --all "$remote" 2>/dev/null && printf '.')" \
        || fail "could not read the push URL for remote $remote"
    fetch_output="${fetch_output%.}"
    push_output="${push_output%.}"
    fetch_output="${fetch_output%$'\n'}"
    push_output="${push_output%$'\n'}"

    [[ -n "$fetch_output" ]] || fail "remote $remote has no fetch URL"
    [[ -n "$push_output" ]] || fail "remote $remote has no push URL"
    mapfile -t fetch_urls <<<"$fetch_output"
    mapfile -t push_urls <<<"$push_output"
    [[ "${#fetch_urls[@]}" -eq 1 && "${fetch_urls[0]}" == "$expected_fetch" ]] \
        || fail "remote $remote fetch URL set is not exactly the expected Forgejo URL"
    [[ "${#push_urls[@]}" -eq 1 && "${push_urls[0]}" == "$expected_push" ]] \
        || fail "remote $remote push URL set is not exactly the expected Forgejo URL"
}

validate_git_url_command() {
    local url=""
    [ "$#" -eq 2 ] && [ "$1" = "--url" ] || usage
    url="$2"
    safe_git_url "$url" || fail "URL is not a credential-free Forgejo HTTPS URL"
}

run_git_push() {
    local repo="" remote="" expected_fetch="" expected_push="" token_file="" refspec="" ref=""
    local force=0 quiet=0
    local -a git_args

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo|--remote|--expected-fetch-url|--expected-push-url|--token-file|--refspec|--ref)
                [ "$#" -ge 2 ] || usage
                case "$1" in
                    --repo) repo="$2" ;;
                    --remote) remote="$2" ;;
                    --expected-fetch-url) expected_fetch="$2" ;;
                    --expected-push-url) expected_push="$2" ;;
                    --token-file) token_file="$2" ;;
                    --refspec) refspec="$2" ;;
                    --ref) ref="$2" ;;
                esac
                shift 2
                ;;
            --force) force=1; shift ;;
            --quiet) quiet=1; shift ;;
            *) usage ;;
        esac
    done

    [ -n "$repo" ] && [ -n "$remote" ] && [ -n "$expected_fetch" ] \
        && [ -n "$expected_push" ] && [ -n "$token_file" ] || usage
    if [ "$command" = git-push ]; then
        [ -n "$refspec" ] && [ -z "$ref" ] || usage
    else
        [[ "$ref" =~ ^refs/heads/[A-Za-z0-9._/-]+$ ]] || fail "readback requires one exact branch ref"
        [ -z "$refspec" ] && [ "$force" -eq 0 ] && [ "$quiet" -eq 0 ] || usage
    fi
    [[ "$remote" =~ ^[A-Za-z0-9._-]+$ ]] || fail "remote name is invalid"
    safe_git_url "$expected_fetch" || fail "expected fetch URL is not a credential-free Forgejo HTTPS URL"
    safe_git_url "$expected_push" || fail "expected push URL is not a credential-free Forgejo HTTPS URL"
    normalize_git_environment

    # This is deliberately before read_token: an unexpected or ambiguous remote
    # must not get a chance to receive the credential, even if the token file is
    # a blocking FIFO or an attacker controls its contents.
    remote_urls_match_exactly "$repo" "$remote" "$expected_fetch" "$expected_push"
    read_token "$token_file"
    sanitize_debug_environment

    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="$FORGEJO_GIT_CONFIG_KEY"
    export GIT_CONFIG_VALUE_0="Authorization: token $FORGEJO_TOKEN"
    export GIT_TERMINAL_PROMPT=0

    # Git's HTTP URL specificity outranks an unscoped command-line setting.
    # Pin both validated repository URLs, covering push and readback without
    # changing unrelated HTTP options or interpreting inherited configuration.
    git_args=(-C "$repo" -c http.followRedirects=false
        -c "http.$expected_fetch.followRedirects=false"
        -c "http.$expected_push.followRedirects=false")
    if [ "$command" = git-push ]; then
        git_args+=(push)
        [ "$force" -eq 1 ] && git_args+=(--force)
        [ "$quiet" -eq 1 ] && git_args+=(--quiet)
        git_args+=("$remote" -- "$refspec")
    else
        git_args+=(ls-remote --exit-code --refs "$remote" "$ref")
    fi
    exec git "${git_args[@]}"
}

run_rest() {
    local token_file="" method="" url="" body="" body_stdin=0 body_given=0
    local -a curl_args

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --token-file|--method|--url|--body)
                [ "$#" -ge 2 ] || usage
                case "$1" in
                    --token-file) token_file="$2" ;;
                    --method) method="$2" ;;
                    --url) url="$2" ;;
                    --body) body="$2"; body_given=1 ;;
                esac
                shift 2
                ;;
            --body-stdin) body_stdin=1; shift ;;
            *) usage ;;
        esac
    done

    [ -n "$token_file" ] && [ -n "$method" ] && [ -n "$url" ] || usage
    safe_api_url "$url" || fail "REST URL is not a credential-free Forgejo API URL"
    case "$method" in
        GET|POST|PUT|PATCH|DELETE) ;;
        *) fail "REST method is not supported" ;;
    esac
    [ "$body_stdin" -eq 0 ] || [ "$body_given" -eq 0 ] || fail "choose one REST body source"
    if [ "$body_stdin" -eq 1 ]; then
        body="$(< /dev/stdin)"
        body_given=1
    fi
    if [ "$body_given" -eq 1 ]; then
        printf '%s' "$body" | jq -e -s 'length == 1' >/dev/null 2>&1 || fail "REST body must be one JSON value"
    fi

    # URL/method policy is checked before the secret file is opened.
    read_token "$token_file"
    sanitize_debug_environment

    # curl reads the Authorization header from a pipe-backed config file. It is
    # never an argv value, and -q prevents a user curlrc from enabling verbose or
    # trace output. Body data is caller input, not credential plumbing.
    # Keep the config pipe open across the curl exec boundary. A shell-scripted
    # test double may interpose an interpreter, so /dev/fd/3 is more reliable
    # than a process-substitution path whose descriptor can be close-on-exec.
    exec 3< <(printf 'header = "Authorization: token %s"\n' "$FORGEJO_TOKEN")
    curl_args=(
        curl -q --silent --show-error --fail-with-body
        --request "$method"
        --config /dev/fd/3
        --output /dev/fd/4 --write-out '%{http_code}'
    )
    if [ "$body_given" -eq 1 ]; then
        curl_args+=(--header 'Content-Type: application/json' --data-binary @-)
    fi
    curl_args+=("$url")
    local rc=0 status
    # Separate literal body stdin and credential config FD. Preserve response
    # stdout while capturing only the status, without response temp artifacts.
    exec 4>&1
    if status="$(printf '%s' "$body" | "${curl_args[@]}")"; then
        case "$status" in
            2??) rc=0 ;;
            *) printf 'forgejo-auth: unexpected HTTP status %s\n' "$status" >&2; rc=22 ;;
        esac
    else
        rc=$?
    fi
    exec 3<&-
    exec 4>&-
    return "$rc"
}

[ "$#" -gt 0 ] || usage
command="$1"
shift
case "$command" in
    validate-git-url) validate_git_url_command "$@" ;;
    git-push|git-ls-remote) run_git_push "$@" ;;
    rest) run_rest "$@" ;;
    *) usage ;;
esac
