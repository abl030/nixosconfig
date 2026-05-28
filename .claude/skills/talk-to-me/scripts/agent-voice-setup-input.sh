#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
phone_ssh="${PHONE_SSH:-phone}"
doc1_ssh="${DOC1_SSH:-doc1}"
whisper_url="${WHISPER_URL:-https://whisper.ablz.au/v1/audio/transcriptions}"
whisper_model="${WHISPER_MODEL:-large}"
max_seconds="${MAX_SECONDS:-45}"
remote_share=".local/share/agent-voice-input"
remote_config=".config/agent-voice-input"
remote_script="$remote_share/agent-voice-input-termux.sh"
local_inject="$HOME/.local/bin/agent-voice-inject"

sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

eval "$("$script_dir/agent-voice-detect-tmux.sh" --shell)"
target="$AGENT_VOICE_TMUX_TARGET"

install -Dm755 "$script_dir/agent-voice-inject.sh" "$local_inject"

ssh -o ConnectTimeout=8 "$phone_ssh" "mkdir -p '$remote_share' '$remote_config'"
scp -q "$script_dir/agent-voice-input-termux.sh" "$phone_ssh:$remote_script"
ssh -o ConnectTimeout=8 "$phone_ssh" "chmod 700 '$remote_share'; chmod 755 '$remote_script'"
ssh -o ConnectTimeout=8 "$phone_ssh" '
  mkdir -p ~/.termux
  touch ~/.termux/termux.properties
  if grep -q "^[#[:space:]]*allow-external-apps" ~/.termux/termux.properties; then
    sed -i "s/^[#[:space:]]*allow-external-apps[[:space:]]*=.*/allow-external-apps = true/" ~/.termux/termux.properties
  else
    printf "\nallow-external-apps = true\n" >> ~/.termux/termux.properties
  fi
  termux-reload-settings >/dev/null 2>&1 || true
'

# Client-side expansion is intentional here: this command writes the session
# specific tmux target and helper paths into a static phone-side config file.
# shellcheck disable=SC2087
ssh -o ConnectTimeout=8 "$phone_ssh" "cat > '$remote_config/config'" <<EOF
DOC1_SSH=$(sq "$doc1_ssh")
TMUX_TARGET=$(sq "$target")
REMOTE_INJECT=$(sq "$local_inject")
WHISPER_URL=$(sq "$whisper_url")
WHISPER_MODEL=$(sq "$whisper_model")
MAX_SECONDS=$(sq "$max_seconds")
AUDIO_ENCODER='aac'
AUDIO_EXT='m4a'
AUDIO_RATE='16000'
AUDIO_CHANNELS='1'
EOF

missing=$(
  ssh -o ConnectTimeout=8 "$phone_ssh" '
    for c in termux-microphone-record curl jq ssh; do
      command -v "$c" >/dev/null 2>&1 || echo "$c"
    done
  '
)

trigger_packages=$(
  ssh -o ConnectTimeout=8 "$phone_ssh" '
    pm list packages 2>/dev/null |
      grep -Ei "tasker|autovoice|macrodroid|automate|termux.tasker|termux.widget" || true
  '
)

echo "input target: $target ($AGENT_VOICE_TMUX_COMMAND on $AGENT_VOICE_TMUX_TTY)"
echo "phone script: $remote_script"
echo "local inject helper: $local_inject"
echo "termux external command bridge: enabled"

if [ -n "$missing" ]; then
  echo "missing phone commands:" >&2
  printf '%s\n' "$missing" >&2
  exit 70
fi

if [ -n "$trigger_packages" ]; then
  echo "detected trigger package(s):"
  printf '%s\n' "$trigger_packages"
else
  echo "no Tasker/AutoVoice/MacroDroid/Automate trigger package detected"
fi
