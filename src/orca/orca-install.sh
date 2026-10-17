#!/usr/bin/env bash
# Install or update this environment's Orca runtime in the home volume, so a new
# Orca release takes a restart rather than an image rebuild.
#
# Tracks the latest GitHub release, which is what the Mac auto-updates to.
# ORCA_VERSION holds a specific version instead (say, while a release is bad).
# Each version is extracted side by side under $ROOT/<version>, and
# $ROOT/current points at the one the runtime starts from.
#
# `current` only moves while nothing is serving on ORCA_SERVE_PORT. The running
# server and the CLI agents call have to be the same build, so an update found
# while the runtime is up is staged and taken on the next start.
#
# Never blocks startup on the network: if GitHub can't be reached, or a download
# fails its checksum, the installed version keeps serving. It exits non-zero
# only when nothing is installed to fall back on.
#
# Going back to an older version is refused unless ORCA_ALLOW_DOWNGRADE=1: newer
# builds migrate profile state to SQLite, which older ones can't read.
set -uo pipefail

# The feature's options (written by install.sh next to this script) are the
# defaults; environment variables override them.
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=/dev/null
[ -r "$here/options" ] && . "$here/options"
ORCA_VERSION="${ORCA_VERSION:-${ORCA_DEFAULT_VERSION:-}}"
[ "$ORCA_VERSION" = latest ] && ORCA_VERSION=

ROOT="${ORCA_RUNTIME_ROOT:-$HOME/.local/share/orca-runtime}"
RELEASES="${ORCA_RELEASE_BASE:-https://github.com/stablyai/orca/releases}"
PORT="${ORCA_SERVE_PORT:-${ORCA_DEFAULT_PORT:-6768}}"
KEEP=2 # the newest two: current plus one to roll back to

log() { echo "orca-install: $*" >&2; }

mkdir -p "$ROOT"
exec 9>"$ROOT/.lock"
flock -w 900 9 || { log "timed out waiting for another install to finish"; exit 1; }
rm -rf "$ROOT"/.tmp-* # left by an install that was killed; safe under the lock

current=$(readlink "$ROOT/current" 2>/dev/null || true)
current=${current##*/}

installed() { [ -x "$ROOT/$1/AppRun" ]; }

# Keep serving what's installed if there is anything; otherwise fail.
give_up() {
  log "$1"
  if [ -n "$current" ] && installed "$current"; then
    log "keeping $current"
    exit 0
  fi
  log "no Orca runtime installed to fall back on"
  exit 1
}

serving() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }

newer() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]; }

# --- Resolve the target version ----------------------------------------------

if [ -n "${ORCA_VERSION:-}" ]; then
  info_url="$RELEASES/download/v$ORCA_VERSION/latest-linux.yml"
else
  info_url="$RELEASES/latest/download/latest-linux.yml"
fi
info=$(curl -fsSL --max-time 30 "$info_url" 2>/dev/null) || give_up "could not fetch $info_url"

# Top-level keys only: the files list repeats sha512, indented.
version=$(awk '/^version:/ { gsub(/["'\'']/, "", $2); print $2; exit }' <<<"$info")
sha=$(awk '/^sha512:/ { print $2; exit }' <<<"$info")
[ -n "$version" ] && [ -n "$sha" ] || give_up "no version or sha512 in $info_url"

if [ -n "$current" ] && newer "$current" "$version" && [ -z "${ORCA_ALLOW_DOWNGRADE:-}" ]; then
  log "refusing to downgrade from $current to $version: newer builds migrate"
  log "profile state that older ones can't read. ORCA_ALLOW_DOWNGRADE=1 overrides."
  version=$current
fi

# --- Download, verify and extract --------------------------------------------

if ! installed "$version"; then
  tmp=$(mktemp -d "$ROOT/.tmp-$version.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT

  # By tag, not latest/: a release published since the lookup above would
  # otherwise swap the binary out from under its checksum.
  log "downloading $version"
  curl -fsSL --retry 3 --max-time 900 -o "$tmp/orca.AppImage" \
    "$RELEASES/download/v$version/orca-linux.AppImage" ||
    give_up "download of $version failed"

  want=$(printf '%s' "$sha" | base64 -d | od -An -vtx1 | tr -d ' \n')
  got=$(sha512sum "$tmp/orca.AppImage" | cut -d' ' -f1)
  [ "$want" = "$got" ] || give_up "checksum mismatch for $version, discarding it"

  # Extracted rather than mounted, so the container doesn't need /dev/fuse.
  chmod +x "$tmp/orca.AppImage"
  (cd "$tmp" && ./orca.AppImage --appimage-extract >/dev/null) ||
    give_up "could not extract $version"
  rm -rf "${ROOT:?}/$version"
  mv "$tmp/squashfs-root" "$ROOT/$version" || give_up "could not move $version into place"
  log "installed $version"
fi

# --- Switch -------------------------------------------------------------------

if [ "$version" = "$current" ]; then
  log "$current is current"
elif serving; then
  log "staged $version; the runtime on :$PORT stays on $current until it restarts"
else
  ln -sfn "$version" "$ROOT/current.new" && mv -T "$ROOT/current.new" "$ROOT/current"
  log "switched to $version${current:+ from $current}"
  current=$version
fi

# --- CLI on PATH ---------------------------------------------------------------

# Serve doesn't put its CLI on PATH, and agents and the Orca skills need it (the
# skills look for orca-ide, then orca). Linked through `current`, so the CLI
# changes version exactly when the server does. A regular file is left alone:
# that's a launcher something else wrote.
bin="$HOME/.local/bin"
mkdir -p "$bin"
for name in orca-ide orca; do
  if [ -L "$bin/$name" ] || [ ! -e "$bin/$name" ]; then
    ln -sfn "$ROOT/current/resources/bin/orca-ide" "$bin/$name"
  fi
done

# --- Orca skills ---------------------------------------------------------------

# So agents in here use `orca worktree create` and Orca terminals rather than raw
# git worktrees, which Orca hides. Matched to the build, so redone on a switch.
# Best effort: retried on the next start if npx or the network fails.
if [ "$(cat "$ROOT/.skills-version" 2>/dev/null)" != "$current" ]; then
  if "$ROOT/current/resources/bin/orca-ide" skills install \
    --skill orca-cli --skill orchestration --agent claude-code,codex; then
    echo "$current" >"$ROOT/.skills-version"
  else
    log "skills install failed; will retry on the next start"
  fi
fi

# --- Prune ---------------------------------------------------------------------

# Each version is ~800 MB. Keep the newest $KEEP, current, and anything a process
# is still running from (Electron's children carry the versioned path in argv).
if command -v pgrep >/dev/null; then
  mapfile -t versions < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
    grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V)
  for ((i = 0; i < ${#versions[@]} - KEEP; i++)); do
    v=${versions[$i]}
    [ "$v" = "$current" ] && continue
    pgrep -f -- "$ROOT/$v/" >/dev/null && continue
    rm -rf "${ROOT:?}/$v" && log "removed $v"
  done
fi

exit 0
