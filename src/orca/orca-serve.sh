#!/usr/bin/env bash
# Start this container's own Orca runtime. The feature runs it as its
# postStartCommand; run `orca-serve --restart` by hand to restart it, and
# `orca-serve --pair desktop|mobile` for a pairing offer (see below).
#
# Why in the container rather than on the host: Orca resolves SSH targets from
# the *client*, not from the runtime, so "host runtime + SSH into the container"
# is not a combination that exists. Running the runtime inside the container is
# what puts agents on its toolchain and DB. Clients reach it over the network,
# for example a Foreman environment's tailnet name: Foreman publishes no ports,
# and its userspace tailscaled hands inbound tailnet connections to
# 127.0.0.1:<port>, which the runtime's 0.0.0.0 bind covers.
#
# orca-install.sh keeps the runtime up to date, so a new Orca release takes a
# restart rather than an image rebuild. It and the rest of Orca's state live in
# the feature's volume (see place_state), so a rebuild keeps them.
#
# --no-sandbox: the Electron chrome-sandbox helper is not setuid here.
# --supervise: restarts the server with growing delays if it dies. After 6
#   failures in 15 minutes it exits 0 and refuses supervised runs until a new
#   build is installed or --force is passed; a dead runtime whose log ends that
#   way is in that state.
#
# No dbus-run-session or xvfb-run any more. Up to 1.4.191 the runtime needed
# both (without a session bus it never printed a pairing URL, orca#9759). Since
# 1.4.229 it runs on Orca's Node server (orcad) and starts its own Xvfb when
# DISPLAY is unset; checked bare on 2026-10-17, ready in 7s. Keep the xvfb and
# Electron packages in the image for whatever still launches Electron.
set -uo pipefail

# The feature's options (written by install.sh next to this script) are the
# defaults; environment variables override them. Exported so orca-install.sh,
# run below, checks the same port and installs the same version.
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=/dev/null
[ -r "$here/options" ] && . "$here/options"
export ORCA_SERVE_PORT="${ORCA_SERVE_PORT:-${ORCA_DEFAULT_PORT:-6768}}"
export ORCA_VERSION="${ORCA_VERSION:-${ORCA_DEFAULT_VERSION:-}}"
PORT=$ORCA_SERVE_PORT

# The address clients reach the runtime at, advertised in pairing offers. In a
# Foreman environment that's its tailnet name, which the overlay sets as
# TS_HOSTNAME; if a client can't resolve short MagicDNS names, set the
# pairingAddress option or ORCA_PAIRING_ADDRESS to the FQDN
# (<slug>.<tailnet>.ts.net). Elsewhere 127.0.0.1, which pairs only through a
# port forward, rather than failing the lifecycle hook.
PAIRING_ADDRESS="${ORCA_PAIRING_ADDRESS:-${ORCA_DEFAULT_PAIRING_ADDRESS:-${TS_HOSTNAME:-}}}"
if [ -z "$PAIRING_ADDRESS" ]; then
  PAIRING_ADDRESS=127.0.0.1
  echo "orca-serve: no pairing address (pairingAddress option, ORCA_PAIRING_ADDRESS or TS_HOSTNAME); advertising 127.0.0.1" >&2
fi
# Orca's state: its profile (~/.config/orca: the E2EE keypair, paired devices,
# repos, sessions), its credential directory (~/.orca) and the runtime install.
# The feature mounts a volume per environment at /var/lib/orca-feature, and
# place_state (below) keeps all three in a directory of it private to this
# user, with links to it at those paths, so a rebuild keeps them whatever the
# repo does with HOME. Without a usable volume they stay in HOME, as Orca has
# them. ORCA_STATE_VOLUME moves the volume; empty keeps everything in HOME.
STATE_VOLUME=${ORCA_STATE_VOLUME-/var/lib/orca-feature}
HOME_CFG="$HOME/.config/orca"
HOME_DATA="$HOME/.orca"
HOME_RUNTIME="$HOME/.local/share/orca-runtime"
# Set by hand, or inherited from the orca-serve that started the runtime this
# runs under (one of its terminals, or a pairing watcher): used as they are.
OWN_CFG=${ORCA_USER_DATA_PATH:-}
OWN_RUNTIME=${ORCA_RUNTIME_ROOT:-}
CFG=${OWN_CFG:-$HOME_CFG}
RUNTIME_ROOT=${OWN_RUNTIME:-$HOME_RUNTIME}
PRIVATE=
if [ -n "$STATE_VOLUME" ] && [ -d "$STATE_VOLUME" ]; then
  PRIVATE="$(cd "$STATE_VOLUME" && pwd -P)/$(id -un 2>/dev/null || id -u)"
fi
LOG="$HOME/orca-serve.log"

DEVICES="$CFG/orca-devices.json"
STATE="$HOME/.local/state/orca-feature"
WATCHER="$STATE/pairing-watch.pid"

# What a runtime of this environment runs from, wherever its state is or was:
# the runtime install, and the orcad that serve deploys into the profile with
# its own Node and detaches (parent PID 1). Orca is given the volume's paths
# as they are, so its processes name them, not the links in HOME. Matched on
# paths rather than process names, so nothing else named orca-ide is caught.
runtime_paths() {
  printf '%s\n' "$RUNTIME_ROOT/" "$CFG/orcad-artifacts/" "$HOME_RUNTIME/" "$HOME_CFG/orcad-artifacts/"
  [ -z "$PRIVATE" ] || printf '%s\n' "$PRIVATE/runtime/" "$PRIVATE/config/orcad-artifacts/"
}

signal_runtime() {
  local path
  while IFS= read -r path; do
    pkill "-$1" -f -- "$path" 2>/dev/null
  done < <(runtime_paths | sort -u)
  return 0
}

runtime_running() {
  local path
  while IFS= read -r path; do
    pgrep -f -- "$path" >/dev/null && return 0
  done < <(runtime_paths | sort -u)
  return 1
}

# Stops this environment's runtime. TERM first so orcad releases its instance
# lock cleanly.
stop_runtime() {
  signal_runtime TERM
  for _ in $(seq 1 15); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || break
    sleep 1
  done
  signal_runtime 9
  sleep 1
}

# Why the volume can't hold the state, or nothing if it can. It has to be
# mounted: state written to a bare directory goes with the container too, and
# a HOME that is a volume would have kept it. The mount point lets anyone
# create in it, like /tmp (install.sh, and a new volume starts as the image's
# directory), so this works whatever uid the remote user ends up with; the
# directory made in it is this user's alone.
volume_problem() {
  if [ -z "$PRIVATE" ] || ! mountpoint -q "$STATE_VOLUME"; then
    echo "no volume is mounted at $STATE_VOLUME"
  elif [ ! -e "$PRIVATE" ] && [ ! -L "$PRIVATE" ] && ! mkdir -m 700 "$PRIVATE" 2>/dev/null; then
    echo "can't create $PRIVATE"
  elif [ ! -d "$PRIVATE" ] || [ -L "$PRIVATE" ] || [ ! -O "$PRIVATE" ] ||
    ! chmod 700 "$PRIVATE" 2>/dev/null || [ ! -w "$PRIVATE" ]; then
    echo "$PRIVATE isn't a directory of this user's"
  fi
}

# Puts $1, a path in HOME, at $2 in the volume, with a link to it left at $1.
# A directory at $1 is state from before the volume (a HOME that was itself a
# volume), or from a start that couldn't use it. It moves in once, by way of
# $1.moving so an interrupted move picks up where it stopped. If the volume
# already has its own, that one wins and $1 is set aside, or removed when $3
# is "discard" (a runtime install, which is only a download).
into_volume() {
  local home=$1 vol=$2 aside
  rm -rf "$vol.partial"
  if [ -d "$home" ] && [ ! -L "$home" ]; then
    if [ ! -e "$vol" ]; then
      mv -T "$home" "$home.moving" || return 1
    elif [ "$3" = discard ]; then
      rm -rf "$home"
    else
      aside="$home.before-volume-$(date -u +%Y%m%dT%H%M%SZ)"
      mv -T "$home" "$aside" || return 1
      echo "orca-serve: $vol already has Orca's state, so $home is set aside as $aside" >&2
    fi
  fi
  if [ -d "$home.moving" ]; then
    if [ ! -e "$vol" ]; then
      if ! { cp -a "$home.moving" "$vol.partial" && mv -T "$vol.partial" "$vol"; }; then
        rm -rf "$vol.partial"
        mv -T "$home.moving" "$home"
        echo "orca-serve: couldn't move $home into $vol; it stays in HOME for now" >&2
        return 1
      fi
      echo "orca-serve: moved $home into $vol" >&2
    fi
    rm -rf "$home.moving"
  fi
  [ -d "$vol" ] || mkdir -m 700 "$vol" || return 1
  mkdir -p "${home%/*}" && ln -sfn "$vol" "$home"
}

# Keeps Orca's state in the volume when it can, else in HOME, saying so once.
# Only while nothing runs from it: it moves directories.
place_state() {
  local why path
  [ -n "$STATE_VOLUME" ] || return 0
  why=$(volume_problem)
  if [ -n "$why" ]; then
    echo "orca-serve: keeping Orca's state in $HOME, which a rebuild discards: $why" >&2
    # Links an earlier start made into the volume, which can't be used now.
    for path in "$HOME_CFG" "$HOME_DATA" "$HOME_RUNTIME"; do
      [ -L "$path" ] || continue
      case $(readlink "$path") in
        "$STATE_VOLUME"/* | "${PRIVATE:-/nonexistent}"/*) rm -f "$path" ;;
      esac
    done
    return 0
  fi
  # Orca has a setting for where its profile is, so it gets the volume's path.
  # Its credential directory is always ~/.orca, which is why the links are
  # there; the one at ~/.config/orca is for the orca CLI in a shell here.
  if [ -z "$OWN_CFG" ] && into_volume "$HOME_CFG" "$PRIVATE/config" keep; then
    CFG="$PRIVATE/config"
    export ORCA_USER_DATA_PATH="$CFG"
  fi
  into_volume "$HOME_DATA" "$PRIVATE/data" keep
  if [ -z "$OWN_RUNTIME" ] && into_volume "$HOME_RUNTIME" "$PRIVATE/runtime" discard; then
    RUNTIME_ROOT="$PRIVATE/runtime"
    export ORCA_RUNTIME_ROOT="$RUNTIME_ROOT"
  fi
  DEVICES="$CFG/orca-devices.json"
}

# An offer's code is base64url JSON; the device it pairs is its pairedDeviceId.
offer_payload() {
  printf '%s' "${1#*code=}" | tr '_-' '/+' |
    { read -r c; while [ $((${#c} % 4)) -ne 0 ]; do c="$c="; done; printf '%s' "$c"; } |
    base64 -d 2>/dev/null
}

offer_device() {
  offer_payload "$1" | grep -o '"pairedDeviceId":"[^"]*"' | cut -d'"' -f4
}

# A process's start time, which with its pid tells it apart from a later
# process given the same pid. The pid file is in HOME, which can be a volume
# that outlives the container and its processes.
proc_start() {
  local stat
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  # After the command name, which is in parentheses and can hold spaces.
  # shellcheck disable=SC2086 # the fields are what's wanted
  set -- ${stat##*) }
  printf '%s' "${20}"
}

# The pairing URL a runtime printed, from complete lines only: a line still
# being written could hold half a code, and read fails on one without its
# newline. Its code has to decode to a JSON object.
log_offer() {
  local line offer=
  [ -r "$LOG" ] || return 0
  while IFS= read -r line; do
    if [[ $line =~ ^Pairing\ URL:\ (orca://pair\?code=[A-Za-z0-9_-]+=*)$ ]]; then
      offer=${BASH_REMATCH[1]}
    fi
  done <"$LOG"
  [ -n "$offer" ] && offer_payload "$offer" | grep -q '^{.*}$' && printf '%s' "$offer"
}

# Whether a device has connected: orcad keeps every offer in orca-devices.json,
# with lastSeenAt 0 until it's used. Read as flat objects, so formatting
# doesn't matter.
device_seen() {
  tr -d '\n' 2>/dev/null <"$DEVICES" | grep -o '{[^{}]*}' | grep -F "\"$1\"" |
    grep -Eq '"lastSeenAt": *[1-9]'
}

# --watch-pairing <device>: started in the background by --pair. Pairing mode
# isn't supervised, so once the offer has been used this restarts the runtime,
# which a used offer makes supervised. One never used is left as it is after
# ORCA_PAIRING_WATCH_SECONDS: a restart then would kill agents started since.
if [ "${1:-}" = --watch-pairing ]; then
  device=${2:?--watch-pairing needs a device id}
  interval=${ORCA_PAIRING_WATCH_INTERVAL:-2}
  deadline=$(( $(date +%s) + ${ORCA_PAIRING_WATCH_SECONDS:-900} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if device_seen "$device"; then
      # --pair exported these for its own start; this one is the opposite.
      # Same pid, so it's still the watcher while it waits for the lock.
      unset ORCA_PAIRING ORCA_MOBILE_PAIRING
      exec bash "$0" --watcher-restart
    fi
    sleep "$interval"
  done
  pid=
  read -r pid _ 2>/dev/null <"$WATCHER"
  [ "${pid:-}" = "$$" ] && rm -f "$WATCHER"
  exit 0
fi

# One start, stop or pairing at a time: two would kill each other's runtime
# and read each other's offer. Held until this exits, and closed (9>&-) for
# everything it leaves running.
mkdir -p "$STATE"
exec 9>"$STATE/lifecycle.lock"
if ! flock -w "${ORCA_LOCK_WAIT:-300}" 9; then
  echo "orca-serve: another orca-serve is still starting or pairing" >&2
  exit 1
fi

# Anything that replaces the runtime stops the watcher, which would
# otherwise restart the replacement. Only the process it recorded: same pid,
# same start time, and still a watcher.
stop_watcher() {
  local pid='' start=''
  read -r pid start 2>/dev/null <"$WATCHER"
  if [ -n "$pid" ] && [ "$pid" != "$$" ] && [ "$(proc_start "$pid")" = "$start" ] &&
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -Eq -- '--watch-pairing|--watcher-restart'; then
    kill "$pid" 2>/dev/null
  fi
  rm -f "$WATCHER"
}

# --pair desktop|mobile: a pairing offer for another client, printed to stdout
# as one line of JSON ({"value", "qr", "note"}) and nothing else, which is what
# Foreman's connect hook hands back. Orca only prints an offer from an
# unsupervised start, so this restarts the runtime into pairing mode, which
# kills running agents, and leaves a watcher to restart it supervised once the
# offer is used. Existing pairings keep working. The offer is a bearer secret:
# it goes to stdout only, never to stderr.
# The watcher's restart, once it has the lock: only if nothing cancelled it
# while it waited (a pairing or restart that got there first).
if [ "${1:-}" = --watcher-restart ]; then
  pid=''
  read -r pid _ 2>/dev/null <"$WATCHER"
  [ "$pid" = "$$" ] || exit 0
  set -- --restart
fi

pair=
case "${1:-}" in
  --pair)
    case "${2:-}" in
      desktop) export ORCA_PAIRING=1; unset ORCA_MOBILE_PAIRING ;;
      mobile) export ORCA_MOBILE_PAIRING=1; unset ORCA_PAIRING ;;
      *) echo "usage: orca-serve --pair desktop|mobile" >&2; exit 2 ;;
    esac
    pair=$2
    # Everything but the offer goes to stderr.
    exec 3>&1 1>&2
    stop_watcher
    stop_runtime
    # The last offer is in here, and it's no answer to this one.
    rm -f "$LOG"
    ;;
  # Restarts the runtime as below: to leave pairing mode, or take a staged
  # update. It kills running agents. Use this rather than pkill -f over ssh,
  # which matches and kills the ssh session's own shell, since the pattern is
  # on its command line.
  --restart)
    stop_watcher
    stop_runtime
    ;;
esac

# Guard on the port rather than on a process name. postStartCommand runs on
# every container start, and a pgrep-based check both races a process that is
# still shutting down and happily believes a wedged process is healthy. The
# question that actually matters is whether something is serving on $PORT.
#
# bash's /dev/tcp rather than ss or netstat: neither ships in every image (slim
# bases often lack iproute2), and a missing tool makes the check
# fail open silently, which would start a second runtime on every container
# start rather than reporting a problem.
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  exec 3<&- 3>&-
  echo "orca runtime already listening on :$PORT"
  exit 0
fi

# A runtime that's still booting isn't listening yet: orcad takes several seconds
# to bind. If one exists, give it time before treating it as an orphan, or a
# second start during boot (a manual run right after postStart, say) kills it
# and starts over.
if runtime_running; then
  for _ in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
      echo "orca runtime already listening on :$PORT"
      exit 0
    fi
    sleep 1
  done
fi

# Nothing is serving, so anything still running from this runtime is an orphan,
# and every lock and socket a runtime keeps in the profile is stale: the
# Singleton* files, orcad's lock and its o-*.sock sockets. The profile is in
# the feature's volume (or a HOME that is one), so they outlive the container
# that wrote them. A rebuilt container shares the host's kernel, so orcad's
# lock even has the right boot id, and the dead process's pid can belong to
# something else by now: every launch then exits as if another runtime held the
# profile, and the runtime never comes up. These cleanups, and moving the state
# into the volume, are safe only because the port check above failed.
stop_watcher
signal_runtime 9
place_state
rm -f "$CFG/SingletonLock" \
      "$CFG/SingletonSocket" \
      "$CFG/SingletonCookie" \
      "$CFG/orcad.lock" \
      "$CFG"/o-*.sock

# Install or update before starting. Nothing is serving, so this is the one
# point where switching versions can't split the server from the CLI it hands
# agents. Falls back to the installed version when GitHub is unreachable.
bash "$here/orca-install.sh" || {
  echo "no Orca runtime available; see the orca-install lines above" >&2
  exit 1
}
# The versioned path, not the `current` link, so the processes' argv names the
# version they run from and orca-install.sh won't prune it from under them.
RUNTIME=$(readlink -f "$RUNTIME_ROOT/current")

# Pairing mode, or supervised. A supervised server writing to a log redacts the
# pairing URL and QR on purpose (a log must not hold a live bearer offer), so
# the only way to pair is a start without --supervise. That happens on its own
# until some device has connected (every offer is in orca-devices.json, with
# lastSeenAt 0 until it's used), or on request:
#   ORCA_PAIRING=1         print a desktop pairing URL
#   ORCA_MOBILE_PAIRING=1  print a mobile QR instead. It's one or the other, so
#                          pair the desktop first. Existing pairings keep working.
# Pairing mode doesn't restart a crashed server; the next start after a device
# has connected is supervised.
#
# The supervisor gives up after 6 failures in 15 minutes and refuses supervised
# starts until --force. That record is in the profile too, so it can be about a
# previous container's runtime, which held a lock this one didn't have. Nothing
# is running now, so this is a fresh start, and --force lets it try.
SERVE_ARGS=(--no-sandbox --port "$PORT" --pairing-address "$PAIRING_ADDRESS")
if [ -n "${ORCA_MOBILE_PAIRING:-}" ]; then
  SERVE_ARGS+=(--mobile-pairing)
  mode=pairing
elif [ -n "${ORCA_PAIRING:-}" ] || ! grep -Eqs '"lastSeenAt": *[1-9]' "$DEVICES"; then
  mode=pairing
else
  SERVE_ARGS+=(--supervise --force)
  mode=supervised
fi

# In pairing mode the log holds a live offer, so only this user reads it,
# whatever the umask.
(umask 077 && : >>"$LOG") && chmod 600 "$LOG"

# 3>&-: under --pair, fd 3 is the caller's stdout, and a runtime holding it
# open would keep the caller waiting for the end of the offer. 9>&-: the lock.
setsid env -u DISPLAY "$RUNTIME/AppRun" serve "${SERVE_ARGS[@]}" >"$LOG" 2>&1 </dev/null 3>&- 9>&- &

echo "orca runtime $(basename "$RUNTIME") starting on :$PORT ($mode)"
if [ -z "$pair" ]; then
  if [ "$mode" = pairing ]; then
    echo "pairing offer will appear in $LOG; it's a bearer secret. Pair, then run orca-serve --restart"
  fi
  exit 0
fi

offer=
deadline=$(( $(date +%s) + ${ORCA_PAIRING_WAIT:-120} ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  offer=$(log_offer)
  [ -n "$offer" ] && break
  sleep 0.5
done
# Not the log's tail: in pairing mode it can hold the offer's QR code.
if [ -z "$offer" ]; then
  echo "orca-serve: no pairing offer after ${ORCA_PAIRING_WAIT:-120}s; see $LOG" >&2
  exit 1
fi

device=$(offer_device "$offer")
if [ -n "$device" ]; then
  setsid bash "$0" --watch-pairing "$device" >/dev/null 2>&1 </dev/null 3>&- 9>&- &
  echo "$! $(proc_start $!)" >"$WATCHER"
else
  echo "orca-serve: couldn't read the offer's device; run orca-serve --restart once it's paired" >&2
fi

if [ "$pair" = mobile ]; then
  qr=true note="Scan it with the Orca app on your phone."
else
  qr=false note="In Orca, add a remote environment and paste this pairing code."
fi
printf '{"value":"%s","qr":%s,"note":"%s"}\n' "$offer" "$qr" "$note" >&3
