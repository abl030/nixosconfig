#!/usr/bin/env bash
# Encrypted, restorable snapshot of Hermes' canonical session database.
# Publishes a single-root-commit `snapshots` branch, force-replaced each run so
# session churn does not become permanent Git history.
set -euo pipefail

BRAIN="${HERMES_HOME:-$HOME/.hermes}"
TOKEN_FILE="$HOME/.config/hermes-brain/token"
IDENTITY_FILE="$HOME/.config/sops/age/keys.txt"
REMOTE="https://git.ablz.au/abl030/hermes-brain.git"
RECIPIENTS=(
  "age1y6nasu9gplutapjne4yv0uhzrwee6ayf2mygwhphf3nty6x5xddqy4zl4h" # break-glass
  "age17uw7vxe8x3nmg0lu5j33qlh8pxr538jlqhhjngmexdc0macccg8sc8rw63" # doc1 editor
)

die() { printf 'brain-snapshot: FATAL: %s\n' "$*" >&2; exit 1; }
note() { printf 'brain-snapshot: %s\n' "$*"; }

for command in sqlite3 zstd age git sha256sum flock; do
  command -v "$command" >/dev/null || die "missing command: $command"
done
[ -r "$BRAIN/state.db" ] || die "session database unreadable at $BRAIN/state.db"
[ -r "$TOKEN_FILE" ] || die "push token unreadable at $TOKEN_FILE"
[ -r "$IDENTITY_FILE" ] || die "age identity unreadable at $IDENTITY_FILE"

lock="${XDG_RUNTIME_DIR:-/tmp}/hermes-brain-snapshot.lock"
exec 9>"$lock"
flock -n 9 || die "another snapshot is already running"

umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
snapshot="$tmp/state.db"
encrypted="$tmp/state.db.zst.age"
repo="$tmp/repo"

note "taking an online SQLite snapshot"
sqlite3 "$BRAIN/state.db" ".backup '$snapshot'"
[ "$(sqlite3 "$snapshot" 'PRAGMA integrity_check;')" = "ok" ] || die "SQLite integrity check failed"

age_args=()
for recipient in "${RECIPIENTS[@]}"; do age_args+=( -r "$recipient" ); done
note "compressing and encrypting session history"
zstd -q -T0 -9 -c "$snapshot" | age "${age_args[@]}" -o "$encrypted"

# Prove that doc1 can decrypt the exact artifact and that its compressed stream
# is intact before it leaves the machine.
age -d -i "$IDENTITY_FILE" "$encrypted" | zstd -tq -

sessions=$(sqlite3 "$snapshot" 'SELECT count(*) FROM sessions;')
messages=$(sqlite3 "$snapshot" 'SELECT count(*) FROM messages;')
plain_bytes=$(stat -c %s "$snapshot")
encrypted_bytes=$(stat -c %s "$encrypted")
encrypted_sha=$(sha256sum "$encrypted" | cut -d' ' -f1)
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
version=$(hermes --version | sed -n '1p')

mkdir -p "$repo/sessions"
cp "$encrypted" "$repo/sessions/state.db.zst.age"
printf '%s\n' \
  "snapshot_utc=$timestamp" \
  "hermes_version=$version" \
  "sessions=$sessions" \
  "messages=$messages" \
  "sqlite_bytes=$plain_bytes" \
  "encrypted_bytes=$encrypted_bytes" \
  "encrypted_sha256=$encrypted_sha" \
  "compression=zstd-9" \
  "encryption=age:break-glass+doc1-editor" \
  > "$repo/sessions/MANIFEST"
# Backticks below are documentation literals, not shell expansions.
# shellcheck disable=SC2016
printf '%s\n' \
  '# Hermes encrypted session snapshot' \
  '' \
  'This branch is force-replaced on every run and intentionally has one commit.' \
  'It contains the canonical Hermes `state.db`, compressed with zstd and encrypted' \
  'to the homelab break-glass and doc1 editor Age recipients.' \
  '' \
  'Restore into a temporary file first:' \
  '```sh' \
  'age -d -i ~/.config/sops/age/keys.txt sessions/state.db.zst.age | zstd -d -o /tmp/hermes-state.db' \
  "sqlite3 /tmp/hermes-state.db 'PRAGMA integrity_check;'" \
  '```' \
  '' \
  'Stop Hermes before replacing `~/.hermes/state.db`; preserve the current DB and' \
  'its WAL/SHM files until the restored database has been opened successfully.' \
  > "$repo/README.md"

# Use a disposable repository so the 100 MiB encrypted blob never lands in the
# live ~/.hermes object store. A root commit plus force-push keeps only one
# reachable snapshot instead of accumulating opaque, non-deltaable ciphertext.
git -C "$repo" init -q -b snapshots
git -C "$repo" config user.name hermes-brain-writer
git -C "$repo" config user.email hermes-brain-writer@ablz.au
git -C "$repo" add -- README.md sessions/MANIFEST sessions/state.db.zst.age
git -C "$repo" commit -q -m "snapshot: sessions $timestamp"
commit=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" remote add origin "$REMOTE"

token=$(<"$TOKEN_FILE")
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.https://git.ablz.au.extraHeader"
export GIT_CONFIG_VALUE_0="Authorization: token $token"
git -C "$repo" push -q --force origin HEAD:refs/heads/snapshots
remote_commit=$(git -C "$repo" ls-remote origin refs/heads/snapshots | cut -f1)
[ "$remote_commit" = "$commit" ] || die "remote snapshot ref does not match uploaded commit"

note "pushed encrypted snapshot: $sessions sessions, $messages messages, $((encrypted_bytes / 1024 / 1024)) MiB"
note "verified: SQLite integrity, local decryption, compressed stream, and remote ref"
