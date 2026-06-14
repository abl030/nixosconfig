# cratedigger-bump — re-pin the cratedigger-src flake input to its latest
# upstream commit and push the lockfile bump to Forgejo master, signed by the
# rolling bot identity. The forced-command target of the hermes-deploy key on
# doc1 (see modules/nixos/services/hermes-operator-launcher.nix).
#
# Closes the "no nix in the container" gap: the Hermes operator session can't run
# `nix flake update`, so it asks doc1 (which has nix + the bot signing key + the
# push token) to do exactly this one mechanical re-pin. After it pushes, the
# session deploys doc2 to pull the new cratedigger.
#
# Body only (writeShellApplication adds the shebang + `set -euo pipefail` + deps).
REPO=/var/lib/hermes-operator/repo
REMOTE=https://git.ablz.au/abl030/nixosconfig.git
BRANCH=master
INPUT=cratedigger-src
SIGNKEY=/var/lib/rolling-flake-update/bot_signing_key   # trusted bot key (git-signing:nix-bot)
SIGNERS=/etc/fleet-update/allowed_signers
TOKEN_FILE=/run/secrets/forgejo/nixbot-token

[ -r "$SIGNKEY" ] || { echo "cratedigger-bump: missing bot signing key ($SIGNKEY)" >&2; exit 1; }
[ -r "$TOKEN_FILE" ] || { echo "cratedigger-bump: missing push token ($TOKEN_FILE)" >&2; exit 1; }

# Clean checkout of current verified master (own clone — never the live tree).
if [ ! -d "$REPO/.git" ]; then
  git clone --quiet "$REMOTE" "$REPO"
fi
cd "$REPO" || exit 1
git fetch --quiet origin "$BRANCH"
git checkout --quiet -B "$BRANCH" "origin/$BRANCH"
git reset --hard --quiet "origin/$BRANCH"

# Re-pin ONLY cratedigger-src to its latest upstream commit.
nix flake update "$INPUT" >/dev/null 2>&1

if git diff --quiet -- flake.lock; then
  echo "cratedigger-bump: no change — cratedigger-src already at the latest upstream commit"
  exit 0
fi

# Commit with the EXACT rolling-bot identity so the commit verifies under the
# same allowed_signers principal that fleet-update trusts.
git config user.name "nix bot"
git config user.email "acme@ablz.au"
git config gpg.format ssh
git config user.signingkey "$SIGNKEY"
git config commit.gpgsign true
git config gpg.ssh.allowedSignersFile "$SIGNERS"
git add flake.lock
git commit --quiet -m "rolling: bump cratedigger-src (hermes-operator)"

# Refuse to push a commit we can't verify ourselves — fleet-update would reject
# it anyway, so fail loud here instead.
if ! git -c gpg.ssh.allowedSignersFile="$SIGNERS" verify-commit HEAD >/dev/null 2>&1; then
  echo "cratedigger-bump: signature self-check FAILED — not pushing" >&2
  exit 3
fi

newrev=$(git rev-parse HEAD)
git -c http.extraHeader="Authorization: token $(cat "$TOKEN_FILE")" push --quiet origin "$BRANCH"
echo "cratedigger-bump: pushed ${newrev} — cratedigger-src re-pinned. Now: ssh abl030@192.168.1.35 deploy"
