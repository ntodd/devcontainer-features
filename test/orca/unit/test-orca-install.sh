#!/usr/bin/env bash
# Unit tests for src/orca/orca-install.sh, against fake releases served over
# file:// so they run offline and in seconds. Linux only, like the script, and
# needs python3 and openssl:
#
#   bash test/orca/unit/test-orca-install.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../../src/orca/orca-install.sh"
W=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT

REL="$W/releases"
export ORCA_RELEASE_BASE="file://$REL"
export ORCA_RUNTIME_ROOT="$W/root"
export ORCA_SERVE_PORT=47123
export SKILLS_LOG="$W/skills.log"
export HOME="$W/home"
ROOT=$ORCA_RUNTIME_ROOT
BIN="$HOME/.local/bin"
: >"$SKILLS_LOG"

pass=0 fail=0
check() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1"; sed 's/^/     | /' "$W/out" 2>/dev/null; fi
}

# A fake AppImage that, like the real one, extracts to ./squashfs-root. Its
# orca-ide records every call so the skills step can be checked.
make_release() {
  local v=$1 d="$REL/download/v$1" sha
  mkdir -p "$d"
  cat >"$d/orca-linux.AppImage" <<EOF
#!/bin/sh
[ "\$1" = --appimage-extract ] || exit 2
mkdir -p squashfs-root/resources/bin
printf '#!/bin/sh\necho $v\n' >squashfs-root/AppRun
printf '#!/bin/sh\necho "$v \$*" >>"\$SKILLS_LOG"\n' >squashfs-root/resources/bin/orca-ide
chmod +x squashfs-root/AppRun squashfs-root/resources/bin/orca-ide
EOF
  sha=$(openssl dgst -sha512 -binary "$d/orca-linux.AppImage" | base64 -w0)
  printf 'version: %s\nfiles:\n  - url: orca-linux.AppImage\n    sha512: %s\npath: orca-linux.AppImage\nsha512: %s\n' \
    "$v" "$sha" "$sha" >"$d/latest-linux.yml"
}
set_latest() { mkdir -p "$REL/latest/download" && cp "$REL/download/v$1/latest-linux.yml" "$REL/latest/download/"; }
current() { local r; r=$(readlink "$ROOT/current" 2>/dev/null); echo "${r##*/}"; }
run() { bash "$SUT" >"$W/out" 2>&1; echo $? >"$W/rc"; }
rc() { cat "$W/rc"; }
skill_runs() { wc -l <"$SKILLS_LOG" | tr -d ' '; }
listen() {
  python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',${1:-$ORCA_SERVE_PORT})); s.listen(); time.sleep(120)" &
  LPID=$!
  sleep 0.5
}
unlisten() { kill "$LPID"; wait "$LPID" 2>/dev/null; }

# 1. Nothing installed and no release reachable: there's nothing to serve.
run
check "fails with nothing installed and no release" '[ "$(rc)" != 0 ] && [ -z "$(current)" ]'

# 2. Fresh install of the latest release, plus the Orca skills.
make_release 1.0.0 && set_latest 1.0.0
run
check "installs latest" '[ "$(rc)" = 0 ] && [ "$(current)" = 1.0.0 ] && [ -x "$ROOT/1.0.0/AppRun" ]'
check "installs skills for the new version" \
  'grep -qx "1.0.0 skills install --skill orca-cli --skill orchestration --agent claude-code,codex" "$SKILLS_LOG"'

check "links orca-ide and orca onto PATH" \
  '[ "$(readlink -f "$BIN/orca-ide")" = "$ROOT/1.0.0/resources/bin/orca-ide" ] && [ "$(readlink -f "$BIN/orca")" = "$ROOT/1.0.0/resources/bin/orca-ide" ]'

# 3. Up to date: no re-extract, no second skills install.
touch "$ROOT/1.0.0/marker"
run
check "leaves an up-to-date install alone" '[ "$(rc)" = 0 ] && [ -e "$ROOT/1.0.0/marker" ] && [ "$(skill_runs)" = 1 ]'

# 4. Newer release, runtime stopped: switch to it.
make_release 1.1.0 && set_latest 1.1.0
run
check "switches to a newer release when not serving" '[ "$(rc)" = 0 ] && [ "$(current)" = 1.1.0 ]'
check "CLI links follow the switch" '[ "$(readlink -f "$BIN/orca-ide")" = "$ROOT/1.1.0/resources/bin/orca-ide" ]'
check "reinstalls skills after switching" '[ "$(skill_runs)" = 2 ] && tail -1 "$SKILLS_LOG" | grep -q "^1.1.0 "'

# 4b. A launcher something else wrote is left alone.
rm "$BIN/orca" && echo '# not ours' >"$BIN/orca"
run
check "leaves a foreign ~/.local/bin/orca alone" '[ "$(cat "$BIN/orca")" = "# not ours" ]'

# 5. Newer release while the runtime is serving: stage it, don't switch.
make_release 1.2.0 && set_latest 1.2.0
listen
run
check "stages without switching while serving" \
  '[ "$(rc)" = 0 ] && [ "$(current)" = 1.1.0 ] && [ -x "$ROOT/1.2.0/AppRun" ] && grep -qi staged "$W/out"'
check "no skills install for a staged version" '[ "$(skill_runs)" = 2 ]'
unlisten

# 6. Next start: switch to the staged version without downloading it again.
rm "$REL/download/v1.2.0/orca-linux.AppImage"
run
check "switches to a staged version without downloading" '[ "$(rc)" = 0 ] && [ "$(current)" = 1.2.0 ]'

# 7. Prune to the newest two.
check "prunes old versions" '[ ! -e "$ROOT/1.0.0" ] && [ -d "$ROOT/1.1.0" ]'

# 8. A version something is still running from isn't pruned.
make_release 1.3.0 && set_latest 1.3.0
bash -c 'exec -a "$0" sleep 60' "$ROOT/1.1.0/AppRun" &
SPID=$!
sleep 0.3
run
check "keeps a version that is still running" '[ "$(current)" = 1.3.0 ] && [ -d "$ROOT/1.1.0" ] && [ -d "$ROOT/1.2.0" ]'
kill "$SPID"; wait "$SPID" 2>/dev/null

# 9. Checksum mismatch: keep serving the installed version.
make_release 1.4.0 && echo corrupt >>"$REL/download/v1.4.0/orca-linux.AppImage" && set_latest 1.4.0
run
check "rejects a bad checksum and keeps current" \
  '[ "$(rc)" = 0 ] && [ "$(current)" = 1.3.0 ] && [ ! -e "$ROOT/1.4.0" ] && grep -qi checksum "$W/out"'

# 10. GitHub unreachable: keep serving the installed version.
rm -rf "$REL/latest"
run
check "keeps current when the release can't be fetched" '[ "$(rc)" = 0 ] && [ "$(current)" = 1.3.0 ]'

# 11. Pinning an older version is refused: newer builds migrate profile state.
ORCA_VERSION=1.2.0 run
check "refuses a downgrade" '[ "$(rc)" = 0 ] && [ "$(current)" = 1.3.0 ] && grep -qi downgrade "$W/out"'

# 12. ...unless explicitly allowed.
ORCA_VERSION=1.2.0 ORCA_ALLOW_DOWNGRADE=1 run
check "downgrades when allowed" '[ "$(rc)" = 0 ] && [ "$(current)" = 1.2.0 ]'

# 13. No temp directories left behind.
check "cleans up temp dirs" '! ls -d "$ROOT"/.tmp-* >/dev/null 2>&1'

# 14. Feature options: the feature writes an options file next to the script.
# The version option applies when ORCA_VERSION is unset...
mkdir -p "$W/feat" && cp "$SUT" "$W/feat/orca-install.sh"
printf "ORCA_DEFAULT_VERSION='1.3.0'\nORCA_DEFAULT_PORT='6768'\n" >"$W/feat/options"
bash "$W/feat/orca-install.sh" >"$W/out" 2>&1
check "uses the version option" '[ "$(current)" = 1.3.0 ]'

# 15. ...and ORCA_VERSION overrides it.
ORCA_VERSION=1.2.0 ORCA_ALLOW_DOWNGRADE=1 bash "$W/feat/orca-install.sh" >"$W/out" 2>&1
check "ORCA_VERSION overrides the option" '[ "$(current)" = 1.2.0 ]'

# 16. "latest" tracks the latest release, and the port option decides whether
# the runtime is serving: here it is, so the update is only staged.
make_release 1.5.0 && set_latest 1.5.0
printf "ORCA_DEFAULT_VERSION='latest'\nORCA_DEFAULT_PORT='47124'\n" >"$W/feat/options"
listen 47124
env -u ORCA_SERVE_PORT bash "$W/feat/orca-install.sh" >"$W/out" 2>&1
check "'latest' option stages the latest release, using the port option" \
  '[ "$(current)" = 1.2.0 ] && [ -x "$ROOT/1.5.0/AppRun" ] && grep -q ":47124" "$W/out"'
unlisten

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
