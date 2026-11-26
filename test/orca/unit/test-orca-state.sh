#!/usr/bin/env bash
# Unit tests for where src/orca/orca-serve.sh keeps Orca's state: the
# profile (~/.config/orca), the credential directory (~/.orca) and the runtime
# install, in the feature's volume when one is mounted, else in HOME. A rebuild
# here is HOME wiped with the volume kept, which is what recreating a container
# whose HOME isn't a volume does. Against a fake runtime, a stubbed
# orca-install.sh and a stubbed mountpoint. Linux only, like the script:
#
#   bash test/orca/unit/test-orca-state.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../../../src/orca"
W=$(mktemp -d)
trap 'pkill -f -- "$W/" 2>/dev/null; chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT

mkdir -p "$W/bin" "$W/stub"
cp "$SRC/orca-serve.sh" "$W/bin/orca-serve.sh"

export HOME="$W/home"
export ORCA_STATE_VOLUME="$W/vol"
export ORCA_SERVE_PORT=47126
export ORCA_PAIRING_ADDRESS=env-1
export ORCA_PAIRING_WAIT=10
export ORCA_PAIRING_WATCH_INTERVAL=0.2
unset ORCA_RUNTIME_ROOT ORCA_USER_DATA_PATH
USER_NAME=$(id -un)
VOL="$ORCA_STATE_VOLUME"
PRIV="$VOL/$USER_NAME"
ARGS="$W/apprun.args"
SEEN="$W/apprun.env"
INSTALLS="$W/install.log"

# The volume's mount point as the image leaves it: anyone may create in it,
# like /tmp. FAKE_MOUNT is what the stubbed mountpoint calls a mount.
export FAKE_MOUNT="$VOL"
cat >"$W/stub/mountpoint" <<'EOF'
#!/bin/sh
[ "$1" = -q ] && shift
[ "$1" = "$FAKE_MOUNT" ]
EOF
chmod +x "$W/stub/mountpoint"
export PATH="$W/stub:$PATH"

# orca-install.sh, which installs into ORCA_RUNTIME_ROOT (or HOME's default),
# and logs a download when there's nothing installed yet.
cat >"$W/bin/orca-install.sh" <<EOF
#!/bin/sh
root=\${ORCA_RUNTIME_ROOT:-\$HOME/.local/share/orca-runtime}
if [ ! -x "\$root/current/AppRun" ]; then
  echo "download \$root" >>"$INSTALLS"
  mkdir -p "\$root/1.0.0"
  cp "$W/AppRun" "\$root/1.0.0/AppRun"
  ln -sfn 1.0.0 "\$root/current"
else
  echo "current \$root" >>"$INSTALLS"
fi
EOF

# A runtime that, like Orca, keeps its profile in ORCA_USER_DATA_PATH (else
# ~/.config/orca) and its credential key in ~/.orca whatever that is, makes an
# E2EE keypair once, and, unsupervised, prints an offer for a new device.
cat >"$W/AppRun" <<EOF
#!/bin/sh
cfg=\${ORCA_USER_DATA_PATH:-\$HOME/.config/orca}
echo "\$*" >>"$ARGS"
echo "\${ORCA_USER_DATA_PATH:-}" >"$SEEN"
mkdir -p "\$cfg" "\$HOME/.orca"
[ -e "\$cfg/orca-e2ee-keypair.json" ] || echo "key-\$\$" >"\$cfg/orca-e2ee-keypair.json"
[ -e "\$HOME/.orca/orcad-secret-store-x.json" ] || echo "seal-\$\$" >"\$HOME/.orca/orcad-secret-store-x.json"
case "\$*" in
  *--supervise*) echo "Pairing URL: hidden because this supervised server is not writing to a terminal." ;;
  *)
    id="dev-\$\$"
    printf '[{"deviceId": "%s", "lastSeenAt": 0}]\n' "\$id" >"\$cfg/orca-devices.json"
    code=\$(printf '{"v":2,"pairedDeviceId":"%s"}' "\$id" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    echo "Pairing URL: orca://pair?code=\$code"
    ;;
esac
exec sleep 60
EOF
chmod +x "$W/AppRun"

pass=0 fail=0
check() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1"; sed 's/^/     | /' "$W/out" 2>/dev/null; fi
}

fresh() {
  pkill -f -- "$W/" 2>/dev/null; sleep 0.3
  chmod -R u+rwx "$HOME" "$VOL" 2>/dev/null
  rm -rf "$HOME" "$VOL" "$ARGS" "$SEEN" "$INSTALLS"
  mkdir -p "$HOME" "$VOL" && chmod 1777 "$VOL"
}
# A rebuild: the container and its HOME are new, the volume isn't.
rebuild() {
  pkill -f -- "$W/" 2>/dev/null; sleep 0.3
  rm -rf "$HOME" "$ARGS" "$SEEN" "$INSTALLS"
  mkdir -p "$HOME"
}
run() {
  bash "$W/bin/orca-serve.sh" "$@" >"$W/out" 2>&1
  echo $? >"$W/rc"
  for _ in $(seq 1 30); do [ -s "$ARGS" ] && break; sleep 0.1; done
}
rc() { cat "$W/rc"; }
started_with() { [ -s "$ARGS" ] && tail -n 1 "$ARGS" | grep -q -- "$1"; }
links_to() { [ -L "$1" ] && [ "$(readlink -f "$1")" = "$(readlink -f "$2")" ]; }
mode() { stat -c %a "$1"; }
downloads() { grep -c '^download' "$INSTALLS" 2>/dev/null || true; }
pair_used() { sed -i -E 's/"lastSeenAt": *0/"lastSeenAt": 1793035544560/' "$1/orca-devices.json"; }
eventually() {
  for _ in $(seq 1 50); do eval "$1" && return 0; sleep 0.2; done
  return 1
}

# 1. A first start with the volume mounted: everything goes in a directory of
#    the volume only this user can open, and HOME's paths lead there.
fresh
run
check "volume: starts" '[ "$(rc)" = 0 ] && [ -s "$ARGS" ]'
check "volume: private directory, owned and 0700" '[ -O "$PRIV" ] && [ "$(mode "$PRIV")" = 700 ]'
check "volume: the profile is there, and Orca is told so" \
  '[ -s "$PRIV/config/orca-e2ee-keypair.json" ] && [ "$(cat "$SEEN")" = "$PRIV/config" ]'
check "volume: the credential directory is there" '[ -s "$PRIV/data/orcad-secret-store-x.json" ]'
check "volume: the runtime is installed there" '[ -x "$PRIV/runtime/current/AppRun" ]'
check "volume: HOME's paths link to it" \
  'links_to "$HOME/.config/orca" "$PRIV/config" && links_to "$HOME/.orca" "$PRIV/data" && links_to "$HOME/.local/share/orca-runtime" "$PRIV/runtime"'
check "volume: a fresh profile pairs" '! started_with --supervise'
key=$(cat "$PRIV/config/orca-e2ee-keypair.json")
seal=$(cat "$PRIV/data/orcad-secret-store-x.json")

# 2. A rebuild once a device has paired: same keypair, same credential key, a
#    supervised start, and no second download. What the old runtime left in the
#    profile is cleared, as it is from HOME.
pair_used "$PRIV/config"
rebuild
echo '{"pid":3835}' >"$PRIV/config/orcad.lock"
: >"$PRIV/config/SingletonLock"
run
check "rebuild: starts supervised, the pairing intact" '[ "$(rc)" = 0 ] && started_with --supervise'
check "rebuild: same E2EE keypair" '[ "$(cat "$PRIV/config/orca-e2ee-keypair.json")" = "$key" ]'
check "rebuild: same credential key" '[ "$(cat "$PRIV/data/orcad-secret-store-x.json")" = "$seal" ]'
check "rebuild: the runtime isn't downloaded again" '[ "$(downloads)" = 0 ]'
check "rebuild: HOME's paths link to the volume again" \
  'links_to "$HOME/.config/orca" "$PRIV/config" && links_to "$HOME/.orca" "$PRIV/data" && links_to "$HOME/.local/share/orca-runtime" "$PRIV/runtime"'
check "rebuild: clears the old runtime's lock files" '[ ! -e "$PRIV/config/orcad.lock" ] && [ ! -e "$PRIV/config/SingletonLock" ]'

# 3. Pairing another client still works, and the offer's device is recorded
#    in the volume, where the watcher looks for it.
run --pair desktop
check "pair: prints an offer" 'tail -n 1 "$W/out" | grep -q "^{\"value\":\"orca://pair?code="'
check "pair: the offer's device is in the volume's profile" 'grep -q "\"lastSeenAt\": 0" "$PRIV/config/orca-devices.json"'
pair_used "$PRIV/config"
check "pair: once used, the runtime goes back to supervised" 'eventually "started_with --supervise"'

# 4. An existing install whose HOME was a volume: its paired profile,
#    credentials and runtime move into the new volume once, and only the
#    volume's copy is left.
fresh
mkdir -p "$HOME/.config/orca" "$HOME/.orca" "$HOME/.local/share/orca-runtime/1.0.0"
chmod 700 "$HOME/.config/orca" "$HOME/.orca"
echo old-key >"$HOME/.config/orca/orca-e2ee-keypair.json"
echo '[{"deviceId": "old", "lastSeenAt": 1792611797280}]' >"$HOME/.config/orca/orca-devices.json"
echo old-seal >"$HOME/.orca/orcad-secret-store-x.json"
cp "$W/AppRun" "$HOME/.local/share/orca-runtime/1.0.0/AppRun"
ln -s 1.0.0 "$HOME/.local/share/orca-runtime/current"
run
check "move: starts supervised with the moved profile" '[ "$(rc)" = 0 ] && started_with --supervise'
check "move: the profile is in the volume" '[ "$(cat "$PRIV/config/orca-e2ee-keypair.json")" = old-key ]'
check "move: the credentials are in the volume" '[ "$(cat "$PRIV/data/orcad-secret-store-x.json")" = old-seal ]'
check "move: the runtime is in the volume, not downloaded" '[ -x "$PRIV/runtime/1.0.0/AppRun" ] && [ "$(downloads)" = 0 ]'
check "move: HOME keeps links, not copies" \
  'links_to "$HOME/.config/orca" "$PRIV/config" && links_to "$HOME/.orca" "$PRIV/data" && links_to "$HOME/.local/share/orca-runtime" "$PRIV/runtime"'
check "move: nothing left half-moved" '! ls -d "$HOME"/.config/orca.* "$HOME"/.orca.* "$PRIV"/*.partial >/dev/null 2>&1'
check "move: says so" 'grep -q "moved $HOME/.config/orca" "$W/out"'
check "move: keeps it private" '[ "$(mode "$PRIV/config")" = 700 ] && [ "$(mode "$PRIV/data")" = 700 ]'

# 5. HOME has a profile and so does the volume (a start that couldn't use the
#    volume made one in HOME): the volume's wins, and HOME's is set aside,
#    not deleted. A runtime install in HOME is only a download: it goes.
fresh
run
pkill -f -- "$W/" 2>/dev/null; sleep 0.3
volkey=$(cat "$PRIV/config/orca-e2ee-keypair.json")
rm "$HOME/.config/orca" "$HOME/.local/share/orca-runtime"
mkdir -p "$HOME/.config/orca" "$HOME/.local/share/orca-runtime/9.9.9"
echo home-key >"$HOME/.config/orca/orca-e2ee-keypair.json"
run
check "both: the volume's profile is used" \
  '[ "$(cat "$PRIV/config/orca-e2ee-keypair.json")" = "$volkey" ] && links_to "$HOME/.config/orca" "$PRIV/config"'
check "both: HOME's profile is set aside, intact" \
  'grep -qx home-key "$HOME"/.config/orca.before-volume-*/orca-e2ee-keypair.json'
check "both: says where it went" 'grep -q "$HOME/.config/orca.before-volume-" "$W/out"'
check "both: HOME's runtime install is removed, not kept" \
  'links_to "$HOME/.local/share/orca-runtime" "$PRIV/runtime" && ! ls -d "$HOME"/.local/share/orca-runtime.* >/dev/null 2>&1'

# 6. A move that was interrupted: finished from where it stopped, or tidied
#    up if the volume's copy was already in place.
fresh
mkdir -p "$HOME/.orca.moving" && echo half-moved >"$HOME/.orca.moving/orcad-secret-store-x.json"
run
check "interrupted: the move is finished" \
  '[ "$(cat "$PRIV/data/orcad-secret-store-x.json")" = half-moved ] && [ ! -e "$HOME/.orca.moving" ]'
pkill -f -- "$W/" 2>/dev/null; sleep 0.3
mkdir -p "$HOME/.config/orca.moving" && echo stale >"$HOME/.config/orca.moving/orca-e2ee-keypair.json"
run
check "interrupted: a copy already in the volume stays, the leftover goes" \
  '[ "$(cat "$PRIV/config/orca-e2ee-keypair.json")" != stale ] && [ ! -e "$HOME/.config/orca.moving" ]'

# 7. No volume mounted: state stays in HOME as before, with one line saying a
#    rebuild loses it, and the runtime still starts.
fresh
FAKE_MOUNT=none run
check "no volume: starts" '[ "$(rc)" = 0 ] && [ -s "$ARGS" ]'
check "no volume: state is in HOME, as directories" \
  '[ -d "$HOME/.config/orca" ] && [ ! -L "$HOME/.config/orca" ] && [ ! -L "$HOME/.orca" ] && [ -x "$HOME/.local/share/orca-runtime/current/AppRun" ]'
check "no volume: Orca isn't pointed anywhere else" '[ -z "$(cat "$SEEN")" ]'
check "no volume: one line about it" '[ "$(grep -c "rebuild" "$W/out")" = 1 ]'
check "no volume: nothing written to the mount point" '[ -z "$(ls -A "$VOL")" ]'

# 7b. ...including when an earlier start linked HOME into a volume that's
#     gone: the links go, so Orca doesn't write through them.
fresh
run
pkill -f -- "$W/" 2>/dev/null; sleep 0.3
rm -rf "$VOL" "$ARGS"
FAKE_MOUNT=none run
check "volume gone: starts, from HOME" \
  '[ "$(rc)" = 0 ] && [ -s "$ARGS" ] && [ -d "$HOME/.config/orca" ] && [ ! -L "$HOME/.config/orca" ] && [ ! -L "$HOME/.orca" ]'

# 8. A volume this user can't write: HOME, one line, and a start.
fresh
chmod 555 "$VOL"
run
check "unwritable: starts from HOME" '[ "$(rc)" = 0 ] && [ -s "$ARGS" ] && [ ! -L "$HOME/.config/orca" ]'
check "unwritable: one line about it" '[ "$(grep -c "rebuild" "$W/out")" = 1 ]'
chmod 1777 "$VOL"

# 8b. The private directory must be a directory of this user's, not a link.
fresh
mkdir "$W/elsewhere" && ln -s "$W/elsewhere" "$PRIV"
run
check "linked private dir: refused, starts from HOME" \
  '[ "$(rc)" = 0 ] && [ -s "$ARGS" ] && [ ! -L "$HOME/.config/orca" ] && [ -z "$(ls -A "$W/elsewhere")" ]'
rm -rf "$W/elsewhere"

# 8c. ...and its mode is put back to 0700 if it's looser.
fresh
mkdir -m 755 "$PRIV"
run
check "loose private dir: back to 0700" '[ "$(mode "$PRIV")" = 700 ] && links_to "$HOME/.config/orca" "$PRIV/config"'

# 9. ORCA_RUNTIME_ROOT set by hand is where the runtime goes; the profile still
#    goes in the volume.
fresh
ORCA_RUNTIME_ROOT="$W/own-root" run
check "own runtime root: kept" '[ -x "$W/own-root/current/AppRun" ] && [ ! -e "$PRIV/runtime" ]'
check "own runtime root: profile still in the volume" '[ "$(cat "$SEEN")" = "$PRIV/config" ]'
rm -rf "$W/own-root"

# 10. ORCA_STATE_VOLUME empty keeps everything in HOME, quietly.
fresh
ORCA_STATE_VOLUME='' run
check "disabled: state in HOME" '[ "$(rc)" = 0 ] && [ -d "$HOME/.config/orca" ] && [ ! -L "$HOME/.config/orca" ]'
check "disabled: says nothing about it" '! grep -q "rebuild" "$W/out"'

# 11. Nothing serving: what's left running from the volume's runtime or the
#     orcad it deployed into the profile is an orphan, and goes.
fresh
run
pkill -f -- "$W/" 2>/dev/null; sleep 0.3
# Processes whose command line names those paths, as orcad's and Electron's do.
bash -c 'exec -a "$0" sleep 60' "$PRIV/config/orcad-artifacts/x/orcad" & o1=$!
bash -c 'exec -a "$0" sleep 60' "$PRIV/runtime/1.0.0/helper" & o2=$!
sleep 0.3
run
check "orphans: the profile's orcad is killed" 'eventually "! kill -0 $o1 2>/dev/null"'
check "orphans: the runtime's processes are killed" 'eventually "! kill -0 $o2 2>/dev/null"'
wait $o1 $o2 2>/dev/null

pkill -f -- "$W/" 2>/dev/null
echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
