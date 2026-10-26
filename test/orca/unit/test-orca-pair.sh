#!/usr/bin/env bash
# Unit tests for `orca-serve --pair` and the Foreman connect hook, against a
# fake runtime and a stubbed orca-install.sh. Linux only, like the script:
#
#   bash test/orca/unit/test-orca-pair.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../../../src/orca"
W=$(mktemp -d)
trap 'pkill -f -- "$W/" 2>/dev/null; rm -rf "$W"' EXIT

mkdir -p "$W/bin"
cp "$SRC/orca-serve.sh" "$W/bin/orca-serve.sh"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/orca-install.sh"

export HOME="$W/home"
export ORCA_RUNTIME_ROOT="$W/root"
export ORCA_SERVE_PORT=47125
export ORCA_PAIRING_ADDRESS=env-1
export ORCA_PAIRING_WAIT=10
export ORCA_PAIRING_WATCH_INTERVAL=0.2
CFG="$HOME/.config/orca"
ARGS="$W/apprun.args"
LOG="$HOME/orca-serve.log"
mkdir -p "$CFG"

# A runtime that records how it was started and, like orcad, adds an unused
# offer to orca-devices.json and prints its pairing URL unless supervised.
# The code is base64url JSON naming the offer's device. FAKE_DELAY holds the
# offer back; FAKE_SILENT never prints one.
mkdir -p "$ORCA_RUNTIME_ROOT/1.0.0"
cat >"$ORCA_RUNTIME_ROOT/1.0.0/AppRun" <<EOF
#!/bin/sh
echo "\$*" >>"$ARGS"
case "\$*" in
  *--supervise*) echo "Pairing URL: hidden because this supervised server is not writing to a terminal." ;;
  *)
    # A QR code, say: the offer in a form that isn't its URL.
    [ -n "\${FAKE_SILENT:-}" ] && { echo "QRSECRET"; exec sleep 60; }
    sleep "\${FAKE_DELAY:-0}"
    id="dev-\$\$"
    printf '[{"deviceId": "%s", "scope": "runtime", "lastSeenAt": 0}]\n' "\$id" >"$CFG/orca-devices.json"
    code=\$(printf '{"v":2,"pairedDeviceId":"%s"}' "\$id" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    if [ -n "\${FAKE_PARTIAL:-}" ]; then
      printf 'Pairing URL: orca://pair?code=%s' "\$(printf '%s' "\$code" | cut -c1-6)"
      sleep 1.5
      printf '%s\n' "\$(printf '%s' "\$code" | cut -c7-)"
    else
      echo "Pairing URL: orca://pair?code=\$code"
    fi
    ;;
esac
sleep 60
EOF
chmod +x "$ORCA_RUNTIME_ROOT/1.0.0/AppRun"
ln -sfn "$ORCA_RUNTIME_ROOT/1.0.0" "$ORCA_RUNTIME_ROOT/current"

pass=0 fail=0
check() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1"; sed 's/^/     | /' "$W/out" "$W/err" 2>/dev/null; fi
}

paired() { echo '[{"deviceId": "old", "lastSeenAt": 1792611797280}]' >"$CFG/orca-devices.json"; }
stop_all() { pkill -f -- "$W/" 2>/dev/null; sleep 0.3; rm -f "$ARGS"; }
pair() {
  bash "$W/bin/orca-serve.sh" --pair "$@" >"$W/out" 2>"$W/err"
  echo $? >"$W/rc"
}
rc() { cat "$W/rc"; }
json() { tail -n 1 "$W/out"; }
started_with() { [ -s "$ARGS" ] && tail -n 1 "$ARGS" | grep -q -- "$1"; }
eventually() {
  for _ in $(seq 1 50); do eval "$1" && return 0; sleep 0.2; done
  return 1
}
# The device the offer in the last --pair output names.
device() {
  json | grep -o 'code=[A-Za-z0-9_-]*' | sed 's/^code=//' | tr '_-' '/+' |
    { read -r c; while [ $((${#c} % 4)) -ne 0 ]; do c="$c="; done; printf '%s' "$c"; } |
    base64 -d | grep -o '"pairedDeviceId":"[^"]*"' | cut -d'"' -f4
}
use_offer() {
  printf '[{"deviceId": "%s", "scope": "runtime", "lastSeenAt": 1793035544560}]\n' "$(device)" \
    >"$CFG/orca-devices.json"
}

# 1. A desktop offer from a runtime that's already paired: it restarts into
#    pairing mode, and the offer is the only thing on stdout, as JSON.
paired
pair desktop
check "desktop: succeeds" '[ "$(rc)" = 0 ]'
check "desktop: stdout is one line" '[ "$(wc -l <"$W/out")" = 1 ]'
check "desktop: prints the offer as JSON" \
  'json | grep -Eq "^\{\"value\":\"orca://pair\?code=[A-Za-z0-9_-]+\",\"qr\":false,\"note\":\"[^\"]+\"\}$"'
check "desktop: starts unsupervised" '! started_with --supervise'
check "desktop: not a mobile offer" '! started_with --mobile-pairing'
check "desktop: advertises the pairing address" 'started_with "--pairing-address env-1"'

# 1b. Read through a pipe, the way Foreman's agent reads it, it returns as soon
#     as the offer is out: nothing it leaves running holds stdout open.
stop_all
paired
# Merged with stderr, as the agent reads it: the last line is the result.
timeout 20 bash -c '"$0" --pair desktop 2>&1 | timeout 10 cat; echo "${PIPESTATUS[0]} ${PIPESTATUS[1]}" >"$1"' \
  "$W/bin/orca-serve.sh" "$W/pipe.rc" >"$W/out"
echo $? >"$W/rc"
check "pipe: returns, and so does the reader" '[ "$(rc)" = 0 ] && [ "$(cat "$W/pipe.rc")" = "0 0" ]'
check "pipe: the last line of the merged output is the offer, as JSON" \
  'grep -v "^\s*$" "$W/out" | tail -n 1 | python3 -c "import json,sys; assert json.load(sys.stdin)[\"value\"].startswith(\"orca://pair?code=\")"'
check "pipe: the offer is only on that line" '[ "$(grep -c "orca://" "$W/out")" = 1 ]'

# 1c. The log holds a live offer: only this user can read it.
stop_all
paired
(umask 022 && pair desktop)
check "log: private whatever the umask" '[ "$(stat -c %a "$LOG")" = 600 ]'

# 1d. A line still being written isn't an offer yet.
stop_all
paired
FAKE_PARTIAL=1 pair desktop
check "partial line: waits for the whole code" '[ -n "$(device)" ] && [ "$(device)" != "" ] && json | grep -q "code=[A-Za-z0-9_-]\{20,\}"'

# 2. Once the offer is used, the watcher restarts the runtime supervised.
use_offer
check "watcher: restarts supervised once the offer is used" 'eventually "started_with --supervise"'
stop_all

# 3. A mobile offer is a QR.
paired
pair mobile
check "mobile: succeeds" '[ "$(rc)" = 0 ]'
check "mobile: starts with --mobile-pairing" 'started_with --mobile-pairing'
check "mobile: asks for a QR" 'json | grep -q "\"qr\":true"'
stop_all

# 4. The log from before the restart can't answer: its offer is gone.
paired
printf 'Pairing URL: orca://pair?code=OLDOFFER\n' >"$LOG"
FAKE_DELAY=1 pair desktop
check "stale log: succeeds" '[ "$(rc)" = 0 ]'
check "stale log: not the previous offer" '! grep -q OLDOFFER "$W/out"'
stop_all

# 5. No offer in time: fails, and prints nothing a caller could take for one.
paired
FAKE_SILENT=1 ORCA_PAIRING_WAIT=2 pair desktop
check "no offer: fails" '[ "$(rc)" != 0 ]'
check "no offer: nothing on stdout" '[ ! -s "$W/out" ]'
check "no offer: says why" 'grep -q "no pairing offer" "$W/err"'
check "no offer: doesn't repeat the log, which can hold the offer" '! grep -q QRSECRET "$W/err"'
stop_all

# 6. Unknown kinds are refused before anything restarts.
paired
pair laptop
check "unknown kind: exit 2" '[ "$(rc)" = 2 ]'
check "unknown kind: nothing restarted" '[ ! -e "$ARGS" ]'

# 7. An unused offer leaves the runtime as it is once the watcher gives up:
#    a restart then would kill agents started in the meantime.
paired
ORCA_PAIRING_WATCH_SECONDS=1 pair desktop
sleep 2
check "watcher timeout: no supervised restart" '! started_with --supervise'
stop_all

# 8. A second offer replaces the first one's watcher.
paired
pair desktop
first=$(device)
pair desktop
printf '[{"deviceId": "%s", "lastSeenAt": 1793035544560}]\n' "$first" >"$CFG/orca-devices.json"
sleep 1.5
check "second offer: the first watcher is gone" '! started_with --supervise'
stop_all

# 8b. A restart by hand stops the watcher: once that offer is used, it would
#     otherwise restart the runtime that replaced the one it watched.
paired
pair desktop
bash "$W/bin/orca-serve.sh" --restart >/dev/null 2>&1
starts=$(wc -l <"$ARGS")
use_offer
sleep 1.5
check "manual restart: stops the watcher" '! pgrep -f -- "--watch-pairing" >/dev/null'
check "manual restart: nothing restarts the runtime after it" '[ "$(wc -l <"$ARGS")" = "$starts" ]'
stop_all

# 8b'. So does starting it again after the pairing runtime died.
paired
pair desktop
pkill -9 -f -- "$ORCA_RUNTIME_ROOT/" 2>/dev/null
sleep 0.3
bash "$W/bin/orca-serve.sh" >/dev/null 2>&1
starts=$(wc -l <"$ARGS")
use_offer
sleep 1.5
check "plain start: stops the watcher" '! pgrep -f -- "--watch-pairing" >/dev/null'
check "plain start: nothing restarts the runtime after it" '[ "$(wc -l <"$ARGS")" = "$starts" ]'
stop_all

# 8b''. A pid file left from another container names whatever has that pid
#       now, which isn't the watcher.
sleep 60 &
bystander=$!
mkdir -p "$HOME/.local/state/orca-feature"
echo "$bystander 12345" >"$HOME/.local/state/orca-feature/pairing-watch.pid"
paired
pair desktop
check "stale pid file: leaves another process alone" 'kill -0 "$bystander" 2>/dev/null'
kill "$bystander" 2>/dev/null
stop_all

# 8b'''. A watcher whose offer was used while something else held the lock
#        waits for it; until then it's still the watcher, and cancelling it
#        then means it doesn't restart anything.
paired
pair desktop
STATE_DIR="$HOME/.local/state/orca-feature"
exec 8>"$STATE_DIR/lifecycle.lock"
flock 8
use_offer
eventually 'pgrep -f -- "--watcher-restart" >/dev/null'
check "held lock: the waiting watcher is still recognized as one" \
  'read -r p _ <"$STATE_DIR/pairing-watch.pid" && tr "\0" " " </proc/$p/cmdline | grep -q -- --watcher-restart'
starts=$(wc -l <"$ARGS")
rm -f "$STATE_DIR/pairing-watch.pid"
exec 8>&-
sleep 1.5
check "held lock: once cancelled, it restarts nothing" '[ "$(wc -l <"$ARGS")" = "$starts" ]'
check "held lock: and it's gone" '! pgrep -f -- "--watcher-restart" >/dev/null'
stop_all

# 8c. Two at once take turns: each gets its own offer, of its own kind.
paired
bash "$W/bin/orca-serve.sh" --pair desktop >"$W/a.out" 2>/dev/null &
a=$!
bash "$W/bin/orca-serve.sh" --pair mobile >"$W/b.out" 2>/dev/null &
b=$!
wait $a; ra=$?
wait $b; rb=$?
check "concurrent: both succeed" '[ "$ra" = 0 ] && [ "$rb" = 0 ]'
check "concurrent: each gets its kind" \
  'grep -q "\"qr\":false" "$W/a.out" && grep -q "\"qr\":true" "$W/b.out"'
value() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["value"])' "$1"; }
check "concurrent: two different offers" '[ "$(value "$W/a.out")" != "$(value "$W/b.out")" ]'
check "concurrent: one watcher left" '[ "$(pgrep -fc -- "--watch-pairing")" = 1 ]'
stop_all

# 9. The Foreman connect hook.
HOOK="$SRC/foreman-connect.sh"
mkdir -p "$W/stub"
cat >"$W/stub/orca-serve" <<EOF
#!/bin/sh
echo "orca-serve \$*" >"$W/stub.args"
if [ -n "\${STUB_FAIL:-}" ]; then
  echo "orca-install: 1.4.241 is current" >&2
  echo 'orca-serve: no pairing offer after 120s; see "/home/x/orca-serve.log"' >&2
  exit 1
fi
echo '{"value":"x"}'
EOF
chmod +x "$W/stub/orca-serve"
hook() { PATH="$W/stub:$PATH" sh "$HOOK" "$@" >"$W/out" 2>"$W/err"; echo $? >"$W/rc"; }
hook describe
check "hook describe: succeeds" '[ "$(rc)" = 0 ]'
check "hook describe: is JSON with both actions" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert [a[\"id\"] for a in d[\"actions\"]] == [\"desktop\",\"mobile\"], d" "$W/out"'
check "hook describe: every action asks for confirmation" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert all(a.get(\"confirm\") for a in d[\"actions\"])" "$W/out"'
hook run mobile
check "hook run: hands off to orca-serve --pair" 'grep -qx "orca-serve --pair mobile" "$W/stub.args"'
hook run other
check "hook run: refuses unknown actions" '[ "$(rc)" = 2 ]'
STUB_FAIL=1 hook run desktop
check "hook run: a failure exits non-zero" '[ "$(rc)" = 1 ]'
check "hook run: and explains itself as JSON on its last line" \
  'tail -n 1 "$W/out" | python3 -c "import json,sys; e=json.load(sys.stdin)[\"error\"]; assert \"no pairing offer\" in e, e"'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
