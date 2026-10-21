#!/usr/bin/env bash
# Unit tests for src/orca/orca-serve.sh: what it clears and how it starts the
# runtime, against a fake runtime and a stubbed orca-install.sh. HOME is a
# named volume in a devcontainer, so state the last container's runtime left
# there is still around when a rebuilt one starts. Linux only, like the
# script, and needs python3:
#
#   bash test/orca/unit/test-orca-serve.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../../../src/orca"
W=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT

# The script finds orca-install.sh next to itself; a stub stands in for it.
mkdir -p "$W/bin"
cp "$SRC/orca-serve.sh" "$W/bin/orca-serve.sh"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/orca-install.sh"

export HOME="$W/home"
export ORCA_RUNTIME_ROOT="$W/root"
export ORCA_SERVE_PORT=47124
export ORCA_PAIRING_ADDRESS=env-1
CFG="$HOME/.config/orca"
ARGS="$W/apprun.args"

# A runtime whose AppRun records how it was started and exits.
mkdir -p "$ORCA_RUNTIME_ROOT/1.0.0"
printf '#!/bin/sh\necho "$*" >"%s"\n' "$ARGS" >"$ORCA_RUNTIME_ROOT/1.0.0/AppRun"
chmod +x "$ORCA_RUNTIME_ROOT/1.0.0/AppRun"
ln -sfn "$ORCA_RUNTIME_ROOT/1.0.0" "$ORCA_RUNTIME_ROOT/current"

pass=0 fail=0
check() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1"; sed 's/^/     | /' "$W/out" 2>/dev/null; fi
}

# What a runtime from a previous container leaves in HOME.
leftovers() {
  mkdir -p "$CFG"
  echo '{"pid":3835,"bootId":"same-kernel-as-this-container"}' >"$CFG/orcad.lock"
  rm -f "$CFG/o-3835-f235.sock"
  python3 -c "import socket; socket.socket(socket.AF_UNIX).bind('$CFG/o-3835-f235.sock')"
  : >"$CFG/SingletonLock"
}
paired() { echo '{"devices":[{"lastSeenAt": 1792611797280}]}' >"$CFG/orca-devices.json"; }
unpaired() { rm -f "$CFG/orca-devices.json"; }
run() {
  rm -f "$ARGS"
  bash "$W/bin/orca-serve.sh" >"$W/out" 2>&1
  echo $? >"$W/rc"
  for _ in $(seq 1 20); do [ -s "$ARGS" ] && break; sleep 0.1; done
}
started_with() { [ -s "$ARGS" ] && grep -q -- "$1" "$ARGS"; }
listen() {
  python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$ORCA_SERVE_PORT)); s.listen(); time.sleep(120)" &
  LPID=$!
  sleep 0.5
}
unlisten() { kill "$LPID"; wait "$LPID" 2>/dev/null; }

# 1. A rebuilt container: nothing serving, the old runtime's lock, socket and
#    Singleton file still in HOME. They're stale, so they go.
leftovers && paired
run
check "clears the old runtime's lock" '[ ! -e "$CFG/orcad.lock" ]'
check "clears the old runtime's sockets" '[ ! -e "$CFG/o-3835-f235.sock" ]'
check "clears Singleton files" '[ ! -e "$CFG/SingletonLock" ]'

# 2. The supervisor's give-up record (6 failures in 15 minutes) is about the
#    old container's runtime too, so the supervised start overrides it.
check "starts supervised" 'started_with --supervise'
check "starts with --force, past an old give-up record" 'started_with --force'

# 3. Pairing mode isn't supervised, so there's nothing to force.
leftovers && unpaired
run
check "pairing mode starts without --supervise or --force" \
  '[ -s "$ARGS" ] && ! started_with --supervise && ! started_with --force'

# 4. Something is serving: it's running, so nothing of its is stale.
leftovers && paired
listen
run
check "leaves a serving runtime's lock alone" '[ -e "$CFG/orcad.lock" ] && [ -e "$CFG/o-3835-f235.sock" ]'
check "doesn't start a second runtime" '[ ! -s "$ARGS" ]'
unlisten

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
