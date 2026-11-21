#!/usr/bin/env bash
# fleetssh-vm-matrix.sh -- integration tests for tools/windows/Setup-FleetSSH.ps1
# against a throwaway Windows VM on prom, driven from doc1. Run before re-pinning
# the one-liner in docs/wiki/infrastructure/windows-fleet-ssh-access.md.
#
#   tools/windows/tests/fleetssh-vm-matrix.sh setup     # build the two baselines (once)
#   tools/windows/tests/fleetssh-vm-matrix.sh run [name...]   # all scenarios, or some
#   tools/windows/tests/fleetssh-vm-matrix.sh destroy   # remove the VM
#
# The VM is a linked clone of the gaming template with the GPU removed (so it
# never contends with a gaming VM), plus two disk snapshots:
#   base-feature  OpenSSH Windows feature present; doc1 keys cleared; test users
#                 tadmin (admin), tuser (standard, has a profile), tblank (no password)
#   base-fresh    the same with sshd removed entirely (exercises the MSI install)
# Each scenario rolls back, boots, copies the working-tree script in, runs it as
# a scheduled task (as SYSTEM, or as a user with an elevated token -- the two
# real ways it runs), then checks the panel RESULT, the exit code, and a REAL
# key login from doc1 with the fleet key (~/.ssh/id_ed25519).
#
# Not covered here (no Entra tenant / no OEM suite in the lab): Entra detection
# and third-party firewall detection. Those are unit-tested offline
# (Setup-FleetSSH.Tests.ps1) and confirmed on the next real box.
#
# Env: PROM (root@192.168.1.12), VMID (960), TEMPLATE (117), KEEP_GOING=1.
set -euo pipefail

PROM="${PROM:-root@192.168.1.12}"
VMID="${VMID:-960}"
TEMPLATE="${TEMPLATE:-117}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../Setup-FleetSSH.ps1"
FLEETKEY="$HOME/.ssh/id_ed25519"
PW_ADMIN='Fleet-Test-Admin-1!'
PW_USER='Fleet-Test-User-1!'

prom() { ssh -o BatchMode=yes "$PROM" "$@"; }
log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# gx [timeout]  <<< powershell  -- run PowerShell in the guest, print its output
gx() {
  local t="${1:-60}" b64
  b64="$( (echo "\$ProgressPreference='SilentlyContinue'"; cat) | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
  prom "qm guest exec $VMID --timeout $t -- powershell.exe -NoProfile -NonInteractive -EncodedCommand $b64" |
    jq -r '(."out-data" // ""), (."err-data" // "" | select(startswith("#< CLIXML") | not))'
}

wait_agent() {
  for _ in $(seq 1 60); do prom "qm agent $VMID ping" >/dev/null 2>&1 && return 0; sleep 5; done
  echo "guest agent never came up" >&2; return 1
}

vm_ip() {
  gx <<'EOF' | tr -d '\r' | grep -m1 -E '^[0-9]+\.'
(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169)\.' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
EOF
}

boot_from() {  # snapshot
  prom "qm stop $VMID --skiplock 1 >/dev/null 2>&1 || true; qm rollback $VMID $1 && qm start $VMID" >/dev/null
  wait_agent
  sleep 20   # let autologon and networking settle
}

push_script() {
  local b64 chunk i=0
  gx <<'EOF' >/dev/null
Remove-Item C:\fleettest -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory C:\fleettest | Out-Null
EOF
  b64="$(base64 -w0 "$SCRIPT")"
  while [ $i -lt ${#b64} ]; do
    chunk="${b64:$i:6000}"
    gx <<EOF >/dev/null
Add-Content -Path C:\\fleettest\\s.b64 -Value '$chunk' -NoNewline
EOF
    i=$((i + 6000))
  done
  gx <<'EOF'
[IO.File]::WriteAllBytes('C:\fleettest\Setup-FleetSSH.ps1', [Convert]::FromBase64String((Get-Content C:\fleettest\s.b64 -Raw)))
"pushed $((Get-Item C:\fleettest\Setup-FleetSSH.ps1).Length) bytes"
EOF
}

# run_task <user|SYSTEM> <password|-> <script args...>  -> prints output; sets RC
run_task() {
  local user="$1" pw="$2"; shift 2
  local args="$*"
  gx <<EOF >/dev/null
Remove-Item C:\\fleettest\\out.txt, C:\\fleettest\\done.txt -ErrorAction SilentlyContinue
\$inv = if ('${MODE:-file}' -eq 'mem') { "& ([scriptblock]::Create((Get-Content C:\\fleettest\\Setup-FleetSSH.ps1 -Raw)))" } else { "& 'C:\\fleettest\\Setup-FleetSSH.ps1'" }
\$cmd = "try { \$inv $args *>&1 | Out-File -Encoding utf8 -Width 200 C:\\fleettest\\out.txt; \`\$rc = \`\$LASTEXITCODE } catch { 'STOPPED: ' + \`\$_ | Out-File -Append C:\\fleettest\\out.txt; \`\$rc = \`\$LASTEXITCODE } finally { 'SESSION STILL ALIVE' | Out-File -Append C:\\fleettest\\out.txt; Set-Content C:\\fleettest\\done.txt \`\$rc }"
\$a = New-ScheduledTaskAction -Execute powershell.exe -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + \$cmd + '"')
Unregister-ScheduledTask -TaskName FleetTest -Confirm:\$false -ErrorAction SilentlyContinue
if ('$user' -eq 'SYSTEM') {
  Register-ScheduledTask -TaskName FleetTest -Action \$a -User SYSTEM -RunLevel Highest | Out-Null
} else {
  Register-ScheduledTask -TaskName FleetTest -Action \$a -User '$user' -Password '$pw' -RunLevel Highest | Out-Null
}
Start-ScheduledTask -TaskName FleetTest
EOF
  for _ in $(seq 1 120); do
    RC="$(gx <<'EOF' | tr -d '\r\n '
if (Test-Path C:\fleettest\done.txt) { (Get-Content C:\fleettest\done.txt -Raw).Trim() }
EOF
)"
    [ -n "$RC" ] && break
    sleep 5
  done
  OUT="$(gx <<'EOF' | tr -d '\0'
Get-Content C:\fleettest\out.txt -Raw -ErrorAction SilentlyContinue
EOF
)"
  printf '%s\n' "$OUT" | sed -n '/+----/,$p'
  echo "exit code: ${RC:-<none, timed out>}"
}

make_profile() {  # make_profile <local user> -- a real profile, as a first logon would
  gx <<EOF
Add-Type -TypeDefinition 'using System; using System.Text; using System.Runtime.InteropServices;
public static class UE { [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
  public static extern int CreateProfile(string sid, string name, StringBuilder path, uint len); }'
\$sb = New-Object Text.StringBuilder 260
\$hr = [UE]::CreateProfile((Get-LocalUser '$1').SID.Value, '$1', \$sb, 260)
"profile $1 -> hr=\$hr \$sb"
EOF
}

FAILS=0
check() {  # check <description> <command...>
  if "${@:2}"; then printf '  \033[32mPASS\033[0m %s\n' "$1"; else printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); fi
}
result_is() { printf '%s\n' "$OUT" | grep -qE "^\| RESULT +$1"; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
doc1_login() {  # user expected-whoami-substring
  local got
  got="$(ssh -i "$FLEETKEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
           "$1@$IP" whoami 2>&1 | tr -d '\r')" || true
  echo "    doc1: ssh $1@$IP whoami -> $got"
  [[ "${got,,}" == *"${2,,}"* ]]
}
port_open() { nc -z -w5 "$IP" 22; }

# ------------------------------------------------------------------ scenarios ---
sc_fresh_msi_admin() {
  log "fresh box, no sshd -> MSI install; elevated local admin (tadmin)"
  boot_from base-fresh; IP="$(vm_ip)"; push_script
  run_task tadmin "$PW_ADMIN"
  check "MSI path used"               out_has "OpenSSH Server installed (MSI)"
  check "no Windows-feature attempt"  bash -c "! printf '%s' \"\$0\" | grep -qi capability" "$OUT"
  check "RESULT PASS"                 result_is PASS
  check "exit 0"                      test "$RC" = 0
  check "doc1 key login as tadmin"    doc1_login tadmin '\tadmin'
  log "same box, re-run: idempotent"
  run_task tadmin "$PW_ADMIN"
  check "RESULT PASS again"           result_is PASS
  check "sshd already installed"      out_has "sshd already installed"
  local n
  n="$(gx <<'EOF' | tr -d '\r'
"keys=" + @(Get-Content C:\ProgramData\ssh\administrators_authorized_keys | Select-String 'master-fleet-identity').Count + " blocks=" + @(Select-String -Path C:\ProgramData\ssh\sshd_config -SimpleMatch '# BEGIN fleet-ssh').Count
EOF
)"
  echo "    $n"
  check "key and managed block once"  test "$(echo "$n" | grep -o 'keys=1 blocks=1')" = "keys=1 blocks=1"
}

sc_feature_system_console() {
  log "OpenSSH feature present; run as SYSTEM (RMM/guest-agent path) -> console user"
  boot_from base-feature; IP="$(vm_ip)"; push_script
  run_task SYSTEM -
  check "targets the console user"    out_has "targeting the console user 'abl030'"
  check "RESULT PASS"                 result_is PASS
  check "doc1 key login as abl030"    doc1_login abl030 '\abl030'
}

sc_local_admin_forced() {
  log "-LocalAdmin fleet (the Entra remedy path, forced on a local account)"
  boot_from base-feature; IP="$(vm_ip)"; push_script
  run_task tadmin "$PW_ADMIN" -LocalAdmin fleet
  check "fleet created"               out_has "Created local account 'fleet'"
  check "retargeted"                  out_has "Retargeted: the key goes to 'fleet'"
  check "RESULT PASS"                 result_is PASS
  check "doc1 key login as fleet"     doc1_login fleet '\fleet'
  log "re-run -LocalAdmin fleet: reuses the account"
  run_task tadmin "$PW_ADMIN" -LocalAdmin fleet
  check "reuses fleet"                out_has "Using existing local account 'fleet'"
  check "RESULT PASS again"           result_is PASS
}

sc_script_error_panel() {
  log "unexpected error (invalid account name) still ends with the panel"
  boot_from base-feature; IP="$(vm_ip)"; push_script
  run_task tadmin "$PW_ADMIN" -LocalAdmin "'bad/name'"
  check "RESULT FAIL-SCRIPT-ERROR"    result_is FAIL-SCRIPT-ERROR
  check "error line in panel"         bash -c "printf '%s' \"\$0\" | grep -qE '^\\| ERROR '" "$OUT"
  check "exit 1"                      test "$RC" = 1
}

sc_in_memory() {
  log "the real one-liner path (in memory): pass, then a failure -- the session must survive both"
  boot_from base-feature; IP="$(vm_ip)"; push_script
  MODE=mem run_task tadmin "$PW_ADMIN"
  check "RESULT PASS (in memory)"     result_is PASS
  check "session survives a pass"     out_has "SESSION STILL ALIVE"
  check "doc1 key login as tadmin"    doc1_login tadmin '\tadmin'
  MODE=mem run_task tadmin "$PW_ADMIN" -TargetUser nosuchuser
  check "RESULT FAIL-NO-SUCH-ACCOUNT" result_is FAIL-NO-SUCH-ACCOUNT
  check "stop message, not a crash"   out_has "Setup-FleetSSH stopped with code 1"
  check "session survives a failure"  out_has "SESSION STILL ALIVE"
}

sc_standard_user() {
  log "standard (non-admin) user with a profile, set up by an admin"
  boot_from base-feature; IP="$(vm_ip)"; push_script; make_profile tuser
  run_task tadmin "$PW_ADMIN" -TargetUser tuser
  check "per-user key file"           out_has 'C:\Users\tuser\.ssh\authorized_keys'
  check "RESULT PASS"                 result_is PASS
  check "doc1 key login as tuser"     doc1_login tuser '\tuser'
}

sc_blank_password() {
  # Either outcome is legitimate: on a real POS box a blank-password account worked
  # with key auth. What must hold is honesty: a PASS really logs in from doc1, and
  # a failure shows the blank-password guidance and the sshd log.
  log "blank-password account: an honest result either way"
  boot_from base-feature; IP="$(vm_ip)"; push_script; make_profile tblank
  run_task tadmin "$PW_ADMIN" -TargetUser tblank
  check "panel printed"               out_has "FLEET SSH -- photograph this panel"
  check "blank password detected"     out_has "Account appears to have no password set."
  if result_is PASS; then
    check "PASS is real: doc1 login"  doc1_login tblank '\tblank'
  else
    check "guidance shown"            out_has "Likely cause: blank password"
    check "sshd log shown"            out_has "sshd log since the self-test"
  fi
}

sc_no_such_account() {
  log "unknown -TargetUser: clean failure with the panel"
  boot_from base-feature; IP="$(vm_ip)"; push_script
  run_task tadmin "$PW_ADMIN" -TargetUser nosuchuser
  check "RESULT FAIL-NO-SUCH-ACCOUNT" result_is FAIL-NO-SUCH-ACCOUNT
  check "exit 1"                      test "$RC" = 1
}

sc_no_msi_download() {
  log "no sshd and -NoMsiDownload: manual instructions, exit 2, nothing changed"
  boot_from base-fresh; IP="$(vm_ip)"; push_script
  run_task tadmin "$PW_ADMIN" -NoMsiDownload
  check "RESULT FAIL-NO-SSHD"         result_is FAIL-NO-SSHD
  check "exit 2"                      test "$RC" = 2
  check "manual steps printed"        out_has "Install it by hand"
}

sc_dropped_packets() {
  log "something drops port 22 (stand-in for a third-party firewall): local PASS, doc1 timeout"
  boot_from base-feature; IP="$(vm_ip)"; push_script
  gx <<'EOF' >/dev/null
New-NetFirewallRule -Name FleetTestBlock22 -DisplayName 'test block 22' -Direction Inbound -Action Block -Protocol TCP -LocalPort 22 -RemoteAddress 192.168.0.0/16 | Out-Null
EOF
  run_task tadmin "$PW_ADMIN"
  check "loopback self-test still passes"  result_is PASS
  check "doc1 hint printed"                out_has "nc -vz -w5"
  check "doc1 sees port 22 dropped"        bash -c "! nc -z -w5 $IP 22"
}

ALL=(sc_fresh_msi_admin sc_feature_system_console sc_local_admin_forced sc_script_error_panel sc_in_memory sc_standard_user
     sc_blank_password sc_no_such_account sc_no_msi_download sc_dropped_packets)

# --------------------------------------------------------------------- setup ---
setup() {
  if ! prom "qm status $VMID" >/dev/null 2>&1; then
    log "cloning $TEMPLATE -> $VMID (no GPU)"
    prom "qm clone $TEMPLATE $VMID --name fleetssh-test && qm set $VMID --delete hostpci0 --memory 6144 --balloon 0 --cores 4 --description 'Throwaway test VM for Setup-FleetSSH (tools/windows/tests). Safe to destroy.'"
  fi
  prom "qm status $VMID | grep -q running || qm start $VMID"
  wait_agent; sleep 20
  log "baseline: clear doc1 keys, create test users"
  gx 120 <<EOF
Remove-Item C:\\ProgramData\\ssh\\administrators_authorized_keys -Force -ErrorAction SilentlyContinue
foreach (\$u in @(@{n='tadmin';p='$PW_ADMIN';a=\$true}, @{n='tuser';p='$PW_USER';a=\$false})) {
  if (-not (Get-LocalUser \$u.n -ErrorAction SilentlyContinue)) {
    New-LocalUser \$u.n -Password (ConvertTo-SecureString \$u.p -AsPlainText -Force) -PasswordNeverExpires | Out-Null
  }
  if (\$u.a) { Add-LocalGroupMember -SID S-1-5-32-544 -Member \$u.n -ErrorAction SilentlyContinue }
}
if (-not (Get-LocalUser tblank -ErrorAction SilentlyContinue)) { New-LocalUser tblank -NoPassword | Out-Null; Enable-LocalUser tblank }
# Create profiles: run one trivial task as each password user.
foreach (\$u in @(@{n='tadmin';p='$PW_ADMIN'}, @{n='tuser';p='$PW_USER'})) {
  \$a = New-ScheduledTaskAction -Execute cmd.exe -Argument '/c exit 0'
  Register-ScheduledTask -TaskName "mkprof-\$(\$u.n)" -Action \$a -User \$u.n -Password \$u.p | Out-Null
  Start-ScheduledTask "mkprof-\$(\$u.n)"
}
Start-Sleep 15
Get-CimInstance Win32_UserProfile | Where-Object LocalPath -match 'tadmin|tuser' | ForEach-Object LocalPath
Get-ScheduledTask mkprof-* | Unregister-ScheduledTask -Confirm:\$false
EOF
  prom "qm shutdown $VMID --timeout 120 && qm snapshot $VMID base-feature --description 'feature sshd, test users, no fleet keys'"
  log "base-fresh: remove the OpenSSH feature and its state"
  prom "qm start $VMID"; wait_agent; sleep 20
  gx 600 <<'EOF'
Stop-Service sshd -Force -ErrorAction SilentlyContinue
Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Where-Object State -eq Installed | Remove-WindowsCapability -Online | Out-Null
Remove-Item C:\ProgramData\ssh -Recurse -Force -ErrorAction SilentlyContinue
Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -match 'SSH' | Remove-NetFirewallRule
"sshd now: " + [bool](Get-Service sshd -ErrorAction SilentlyContinue)
EOF
  prom "qm shutdown $VMID --timeout 120 && qm snapshot $VMID base-fresh --description 'no sshd at all'"
  log "setup done: snapshots base-feature, base-fresh"
}

case "${1:-}" in
  setup) setup ;;
  run)
    shift
    list=("$@"); [ ${#list[@]} -eq 0 ] && list=("${ALL[@]}")
    for s in "${list[@]}"; do "$s"; done
    prom "qm shutdown $VMID --timeout 120 >/dev/null 2>&1 || qm stop $VMID" || true
    echo; [ "$FAILS" -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "$FAILS CHECK(S) FAILED"; exit 1; } ;;
  destroy) prom "qm stop $VMID >/dev/null 2>&1 || true; qm destroy $VMID --purge" ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
