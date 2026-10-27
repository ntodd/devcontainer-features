#!/bin/sh
# Installs the orca feature at image build time (as root).
#
# Orca itself isn't installed here. orca-serve installs and updates it in the
# remote user's home on every start (see orca-install.sh), so a new Orca release
# takes a restart rather than an image rebuild. This script installs what that
# needs:
#
#   - the shared libraries and Xvfb Orca's Electron side needs, which slim
#     images don't carry, plus procps (pgrep/pkill) and curl
#   - orca-serve and orca-install under /usr/local/share/orca-feature, with
#     orca-serve on PATH
#   - orca and orca-ide on PATH, pointing into the remote user's install
#   - Foreman's connect hook, so a Foreman environment's page can pair Orca
#     clients (inert anywhere else)
set -eu

VERSION=${VERSION:-latest}
PORT=${PORT:-6768}
PAIRINGADDRESS=${PAIRINGADDRESS:-}

share=/usr/local/share/orca-feature
here=$(cd "$(dirname "$0")" && pwd)

if ! command -v apt-get >/dev/null 2>&1; then
  echo "orca feature: needs a Debian or Ubuntu image (no apt-get here)" >&2
  exit 1
fi

# --- packages ---------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# Debian 13 and Ubuntu 24.04 renamed several libraries with a t64 suffix, and
# the old name is then a virtual package apt won't install by itself.
pick() {
  for name in "$@"; do
    if [ -n "$(apt-cache show "$name" 2>/dev/null | grep -m1 '^Package:')" ]; then
      echo "$name"
      return 0
    fi
  done
  echo "orca feature: none of $* is available" >&2
  return 1
}

# GTK pulls in dbus and systemd (through dconf's session bus), whose packages
# add the messagebus and systemd-network system users. Left to themselves they
# take uids like 996, and on a Foreman box the agent's own user can have that
# uid: the devcontainer CLI then can't move the remote user onto it, so the
# workspace isn't writable. Made here first, out of the system range, the
# packages adopt them.
for user in messagebus:60001:/nonexistent systemd-network:60002:/; do
  name=${user%%:*} id=${user#*:} id=${id%%:*} home=${user##*:}
  if ! getent passwd "$name" >/dev/null; then
    getent group "$name" >/dev/null || groupadd --system --gid "$id" "$name"
    useradd --system --uid "$id" --gid "$name" --no-create-home --home-dir "$home" \
      --shell /usr/sbin/nologin "$name"
  fi
done

packages="ca-certificates curl procps util-linux xvfb xauth libdbus-1-3
  libnss3 libnspr4 libdrm2 libgbm1 libxcomposite1 libxdamage1 libxfixes3
  libxrandr2 libxkbcommon0 libpango-1.0-0 libcairo2 libxshmfence1 libx11-xcb1
  libxcb-dri3-0 libexpat1"
for pair in libglib2.0-0t64:libglib2.0-0 libatk1.0-0t64:libatk1.0-0 \
  libatk-bridge2.0-0t64:libatk-bridge2.0-0 libcups2t64:libcups2 \
  libgtk-3-0t64:libgtk-3-0 libasound2t64:libasound2 \
  libatspi2.0-0t64:libatspi2.0-0; do
  packages="$packages $(pick "${pair%%:*}" "${pair#*:}")"
done

# System users (uid 100-999) the packages add, for the warning below.
system_users() { awk -F: '$3 >= 100 && $3 < 1000 { print $1 "=" $3 }' /etc/passwd | sort; }
users_before=$(system_users)

# shellcheck disable=SC2086 # word splitting is the point
apt-get install -y --no-install-recommends $packages
apt-get clean
rm -rf /var/lib/apt/lists/*

# Any system user a package added can collide with the host user the remote
# user's uid is mapped to, as messagebus did (above).
system_users | grep -vxF "$users_before" | grep -v "^${_REMOTE_USER:-}=" |
  while read -r user; do
    echo "orca feature: warning: a package added system user $user, which can stop the devcontainer CLI giving the remote user that uid" >&2
  done

# --- scripts ----------------------------------------------------------------

mkdir -p "$share"
install -m 0755 "$here/orca-serve.sh" "$share/orca-serve.sh"
install -m 0755 "$here/orca-install.sh" "$share/orca-install.sh"
ln -sf "$share/orca-serve.sh" /usr/local/bin/orca-serve

# Foreman runs connect.d/<name> in an environment to list and run its actions
# (here, pairing another Orca client). Nothing else reads it.
mkdir -p /usr/local/share/foreman/connect.d
install -m 0755 "$here/foreman-connect.sh" /usr/local/share/foreman/connect.d/orca

# Options the scripts read at runtime as defaults. A repo sets these, so each
# value is single-quoted for sourcing.
quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
{
  printf 'ORCA_DEFAULT_VERSION=%s\n' "$(quote "$VERSION")"
  printf 'ORCA_DEFAULT_PORT=%s\n' "$(quote "$PORT")"
  printf 'ORCA_DEFAULT_PAIRING_ADDRESS=%s\n' "$(quote "$PAIRINGADDRESS")"
} >"$share/options"
chmod 0644 "$share/options"

# --- CLI on PATH --------------------------------------------------------------

# Agents and the Orca skills call `orca-ide`, then `orca`. /usr/local/bin is on
# every PATH, unlike ~/.local/bin, which orca-install.sh also links. These
# dangle until orca-serve installs Orca on the first start. A real file already
# at either name is left alone.
target="${_REMOTE_USER_HOME:-/root}/.local/share/orca-runtime/current/resources/bin/orca-ide"
for name in orca-ide orca; do
  if [ -L "/usr/local/bin/$name" ] || [ ! -e "/usr/local/bin/$name" ]; then
    ln -sfn "$target" "/usr/local/bin/$name"
  fi
done
