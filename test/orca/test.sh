#!/bin/bash
# The orca feature with default options, end to end: the real download from
# GitHub, pairing mode on a fresh profile, supervised mode once a device has
# connected, recovery after orcad is killed, and --restart.
#
#   devcontainer features test --features orca --skip-scenarios \
#     --base-image mcr.microsoft.com/devcontainers/base:debian .
set +e
source dev-container-features-test-lib

RR="$HOME/.local/share/orca-runtime"
LOG="$HOME/orca-serve.log"
PORT=6768

up() {
  for _ in $(seq 1 "${1:-90}"); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# Image contents.
check "init is PID 1" bash -c "ps -o args= -p 1 | grep -q docker-init"
check "orca-serve is on PATH" bash -c '[ "$(command -v orca-serve)" = /usr/local/bin/orca-serve ]'
check "options file is installed" grep -q "^ORCA_DEFAULT_PORT='6768'$" /usr/local/share/orca-feature/options
check "Xvfb is installed" bash -c "command -v Xvfb"

# postStartCommand started the runtime (the harness runs lifecycle commands).
up 90 || orca-serve
check "runtime is serving" up
check "latest release is installed" bash -c "[ -x '$RR/current/AppRun' ]"
check "orca CLI on PATH runs the installed version" bash -c \
  '[ "$(orca --version 2>/dev/null | head -1)" = "$(basename "$(readlink '"$RR"'/current)")" ]'
check "fresh profile starts in pairing mode" grep -q '^Pairing URL: orca://pair' "$LOG"

# Pretend the desktop has paired, then restart: now supervised.
sed -i -E 's/"lastSeenAt": *0/"lastSeenAt":1792252400000/' "$HOME/.config/orca/orca-devices.json"
orca-serve --restart
# A second start while that one is still booting (orcad takes seconds to bind)
# must wait for it, not kill it as an orphan and start over.
booting=$(orca-serve 2>&1)
check "a start during boot leaves the booting runtime alone" bash -c "[[ '$booting' == *'already listening'* ]]"
up
check "restart after pairing is supervised" grep -q 'hidden because this supervised server' "$LOG"

# Kill orcad (the process holding the port); the supervisor brings it back.
orcad=$(awk -F'[:,]' '/"pid"/ { print $2; exit }' "$HOME/.config/orca/orcad.lock")
kill -9 "$orcad"
sleep 3
check "supervisor restarts a killed orcad" bash -c "
  for _ in \$(seq 1 90); do
    (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && exit 0
    sleep 1
  done
  exit 1"
check "orcad came back as a new process" bash -c \
  "new=\$(awk -F'[:,]' '/\"pid\"/ { print \$2; exit }' '$HOME/.config/orca/orcad.lock'); [ \"\$new\" != '$orcad' ]"

reportResults
