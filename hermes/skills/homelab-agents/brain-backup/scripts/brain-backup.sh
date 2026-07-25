#!/usr/bin/env bash
# Back up the Hermes "brain" (~/.hermes) to the private abl030/hermes-brain repo.
#
# Reviewed, human-owned procedure — deliberately lives in nixosconfig rather
# than in ~/.hermes/skills so the agent cannot self-patch its own safety rails.
# Rationale and the tracked/excluded split: ~/.hermes/README.md
#
# Fails CLOSED: any suspicion of credential material aborts before committing.
set -euo pipefail

BRAIN="${HERMES_HOME:-$HOME/.hermes}"
TOKEN_FILE="$HOME/.config/hermes-brain/token"
SCAN_MIN_LEN=32

die() { printf 'brain-backup: FATAL: %s\n' "$*" >&2; exit 1; }
note() { printf 'brain-backup: %s\n' "$*"; }

[ -d "$BRAIN/.git" ] || die "$BRAIN is not a git repository"
[ -r "$TOKEN_FILE" ] || die "push token unreadable at $TOKEN_FILE"
cd "$BRAIN"

# The deny-by-default posture is load-bearing. If it is gone, so is our
# guarantee that auth.json/.env cannot be committed.
grep -qx '\*' .gitignore || die ".gitignore no longer denies by default — refusing"

manifest="skills/.bundled_manifest"
[ -r "$manifest" ] || die "missing $manifest — cannot tell authored from bundled skills"

# --- compute the agent-authored skill set --------------------------------
# authored = has SKILL.md, leaf name absent from the bundled manifest, and not
# inside a read-only (nix-store backed) collection.
authored=()
while IFS= read -r dir; do
  leaf="${dir##*/}"
  cut -d: -f1 "$manifest" | grep -qxF "$leaf" && continue
  col="${dir#skills/}"; col="${col%%/*}"
  [ -w "skills/$col" ] || continue
  authored+=("$dir")
done < <(find skills -name SKILL.md -not -path 'skills/.curator_backups/*' -printf '%h\n' | sort -u)

[ "${#authored[@]}" -gt 0 ] || die "computed zero authored skills — refusing (detection bug?)"

# --- durable top-level artifacts ----------------------------------------
durable=()
for f in memories/MEMORY.md memories/USER.md SOUL.md webhook_subscriptions.json cron/jobs.json; do
  [ -f "$f" ] && durable+=("$f")
done
while IFS= read -r h; do [ -n "$h" ] && durable+=("$h"); done \
  < <(find hooks -type f 2>/dev/null || true)

note "allow-set: ${#durable[@]} durable file(s), ${#authored[@]} authored skill(s)"

# --- secret-scan preflight (FAIL CLOSED) --------------------------------
python3 - "$SCAN_MIN_LEN" "${durable[@]}" "${authored[@]}" <<'PY' || die "secret-scan preflight failed — nothing was committed"
import re, sys, pathlib
minlen = int(sys.argv[1])
# Require a long, hyphen-free, mixed alphanumeric run: real tokens look like
# this, slug names like "alert-bridge-rca" deliberately do not.
SUS = re.compile(r'(?i)(token|password|passwd|api[_-]?key|secret|bearer)["\'\s]*[:=]["\'\s]*([A-Za-z0-9+/=_]{%d,})' % minlen)
KEY = re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----')
bad = []
for root in sys.argv[2:]:
    p = pathlib.Path(root)
    files = [p] if p.is_file() else [f for f in p.rglob('*') if f.is_file()]
    for f in files:
        try:
            t = f.read_text(errors='ignore')
        except Exception:
            continue
        if KEY.search(t):
            bad.append((f, 'private key material'))
            continue
        for m in SUS.finditer(t):
            v = m.group(2)
            if any(c.isdigit() for c in v) and any(c.isalpha() for c in v):
                bad.append((f, 'credential-shaped literal'))
                break
for f, why in bad:
    print(f'  !! {f}: {why}', file=sys.stderr)
sys.exit(1 if bad else 0)
PY

# --- stage exactly the allow-set ----------------------------------------
git add -f -- "${durable[@]}" "${authored[@]}"

# --- belt and braces: assert nothing denied slipped into the index ------
staged=$(git diff --cached --name-only)
if printf '%s\n' "$staged" | grep -qE '(^|/)(\.env|auth\.json|auth\.lock)$|^(state\.db|kanban\.db|verification_evidence\.db)|^(sessions|logs|bin|worktrees|pairing|cache|image_cache|audio_cache|pastes)/'; then
  git reset -q
  die "a denied path reached the index — aborted and unstaged"
fi

if git diff --cached --quiet; then
  note "no changes to back up"
  exit 0
fi

count=$(printf '%s\n' "$staged" | grep -c . || true)
git commit -q -m "brain: sync $(date -u +%Y-%m-%dT%H:%M:%SZ)

${count} path(s): memories, SOUL, and agent-authored skills.
Bundled skills, credentials, and runtime state excluded by policy."

GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="http.https://git.ablz.au.extraHeader" \
GIT_CONFIG_VALUE_0="Authorization: token $(cat "$TOKEN_FILE")" \
git push -q origin main

note "pushed ${count} path(s) to abl030/hermes-brain"

# --- post-push assertion ------------------------------------------------
if git ls-files | grep -qE '^(\.env|auth\.json|state\.db)'; then
  die "POST-PUSH: a sensitive file is tracked — rotate the credential and rewrite history"
fi
note "verified: no credential files are tracked"
