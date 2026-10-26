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
# orca-install.sh keeps the runtime in the home volume and up to date, so a new
# Orca release takes a restart rather than an image rebuild.
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
RUNTIME_ROOT="${ORCA_RUNTIME_ROOT:-$HOME/.local/share/orca-runtime}"
LOG="$HOME/orca-serve.log"

DEVICES="$HOME/.config/orca/orca-devices.json"
STATE="$HOME/.local/state/orca-feature"
WATCHER="$STATE/pairing-watch.pid"

# Stops this environment's runtime. TERM first so orcad releases its instance
# lock cleanly.
stop_runtime() {
  pkill -TERM -f -- "$RUNTIME_ROOT/" 2>/dev/null
  pkill -TERM -f -- "$HOME/.config/orca/orcad-artifacts/" 2>/dev/null
  for _ in $(seq 1 15); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || break
    sleep 1
  done
  pkill -9 -f -- "$RUNTIME_ROOT/" 2>/dev/null
  pkill -9 -f -- "$HOME/.config/orca/orcad-artifacts/" 2>/dev/null
  sleep 1
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
# process given the same pid. The pid file is in HOME, a volume that outlives
# the container and its processes.
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
if pgrep -f -- "$RUNTIME_ROOT/" >/dev/null ||
  pgrep -f -- "$HOME/.config/orca/orcad-artifacts/" >/dev/null; then
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
# Singleton* files, orcad's lock and its o-*.sock sockets. They live in $HOME,
# usually a named volume, so they outlive the container that wrote them. A
# rebuilt container shares the host's kernel, so orcad's lock even has the right
# boot id, and the dead process's pid can belong to something else by now: every
# launch then exits as if another runtime held the profile, and the runtime
# never comes up. These cleanups are safe only because the port check above
# failed. Matched on paths rather than process names, so nothing else named
# orca-ide is caught: the runtime root, and orcad, which serve deploys into the
# profile with its own Node and detaches (parent PID 1).
stop_watcher
pkill -9 -f -- "$RUNTIME_ROOT/" 2>/dev/null || true
pkill -9 -f -- "$HOME/.config/orca/orcad-artifacts/" 2>/dev/null || true
rm -f "$HOME/.config/orca/SingletonLock" \
      "$HOME/.config/orca/SingletonSocket" \
      "$HOME/.config/orca/SingletonCookie" \
      "$HOME/.config/orca/orcad.lock" \
      "$HOME/.config/orca"/o-*.sock

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
elif [ -n "${ORCA_PAIRING:-}" ] ||
  ! grep -Eqs '"lastSeenAt": *[1-9]' "$HOME/.config/orca/orca-devices.json"; then
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
