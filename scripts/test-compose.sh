#!/usr/bin/env bash
# Checks the orca feature on a compose-based devcontainer, which
# `devcontainer features test` can't build. A feature's `init`, `mounts` and
# `postStartCommand` reach a compose service only through the override file the
# devcontainer CLI generates, and the orca runtime can't recover without init.
# Then rebuilds it, and checks a paired client still connects.
#
# Uses the CLI version Foreman pins. Needs Docker and Node.
#
#   scripts/test-compose.sh
set -u

CLI="${DEVCONTAINER_CLI:-npx --yes @devcontainers/cli@0.89.0}"
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d)
project=""

cleanup() {
  [ -n "$project" ] && docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT

mkdir -p "$W/app/.devcontainer"
cp -R "$REPO/src/orca" "$W/app/.devcontainer/orca"
cat >"$W/app/.devcontainer/devcontainer.json" <<'EOF'
{
  "name": "orca-compose-check",
  "dockerComposeFile": ["docker-compose.yml"],
  "service": "app",
  "workspaceFolder": "/workspaces",
  "features": { "./orca": {} }
}
EOF
cat >"$W/app/.devcontainer/docker-compose.yml" <<'EOF'
services:
  app:
    image: mcr.microsoft.com/devcontainers/base:debian
    command: sleep infinity
    volumes:
      - ..:/workspaces:cached
      - orca-client:/orca-client
    environment:
      TS_HOSTNAME: orca-compose-check
    # The address offers advertise, as MagicDNS resolves it in a Foreman
    # environment, so a client in here can use one.
    extra_hosts:
      - "orca-compose-check:127.0.0.1"
volumes:
  orca-client:
EOF

echo "devcontainer up ($CLI)"
$CLI up --workspace-folder "$W/app" >"$W/up.json" 2>"$W/up.log"
rc=$?
id=$(grep -o '"containerId":"[^"]*"' "$W/up.json" | head -1 | cut -d'"' -f4)
if [ -n "$id" ]; then
  project=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$id")
fi

pass=0 fail=0
check() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1"; fi
}

check "devcontainer up succeeds" '[ "$rc" = 0 ] && [ -n "$id" ]'
[ -n "$id" ] || { tail -30 "$W/up.log"; exit 1; }
check "compose service has init" '[ "$(docker inspect -f "{{.HostConfig.Init}}" "$id")" = true ]'
check "PID 1 is docker-init" 'docker exec "$id" ps -o args= -p 1 | grep -q docker-init'
check "postStartCommand started the runtime" \
  'docker exec -u vscode "$id" bash -c "for _ in \$(seq 1 90); do (exec 3<>/dev/tcp/127.0.0.1/6768) 2>/dev/null && exit 0; sleep 1; done; exit 1"'
check "pairing offer advertises TS_HOSTNAME" \
  'docker exec -u vscode "$id" bash -c "grep -o \"orca://pair?code=[^ ]*\" ~/orca-serve.log | head -1 | sed \"s/.*code=//\" | tr \"_-\" \"/+\" | { read -r c; while [ \$(( \${#c} % 4 )) -ne 0 ]; do c=\"\$c=\"; done; printf %s \"\$c\"; } | base64 -d 2>/dev/null | grep -q orca-compose-check:6768"'

# --- A rebuild keeps Orca's state ---------------------------------------------

# HOME isn't a volume here, as in a repo that only mounts its workspace, so
# what survives the rebuild is the feature's own volume. The client's HOME is
# a volume of the test's own, so it outlives the container too.
app() { docker exec -u vscode "$id" bash -c "$1"; }
within() {
  for _ in $(seq 1 "$1"); do eval "$2" && return 0; sleep 1; done
  return 1
}
CLIENT=/orca-client
docker exec -u root "$id" chown vscode: "$CLIENT"
RR='~/.local/share/orca-runtime'
connected() { app "HOME=$CLIENT orca status --environment self 2>/dev/null" | grep -q 'ConnectionState: connected'; }
supervised() { app 'grep -q "hidden because this supervised server" ~/orca-serve.log'; }
add_repo() { app "HOME=$CLIENT orca repo add --environment self --path /workspaces --kind folder" >/dev/null 2>&1; }
has_repo() { app "HOME=$CLIENT orca repo list --environment self" 2>/dev/null | grep -q /workspaces; }

check "Orca's state is in the volume, in a directory only vscode opens" \
  'app "mountpoint -q /var/lib/orca-feature && [ \$(stat -c %a /var/lib/orca-feature/vscode) = 700 ] && [ \$(readlink -f ~/.config/orca) = /var/lib/orca-feature/vscode/config ] && [ \$(readlink -f ~/.orca) = /var/lib/orca-feature/vscode/data ]"'
check "/etc/machine-id is kept in the volume" \
  'app "[ \$(readlink /etc/machine-id) = /var/lib/orca-feature/machine-id ] && grep -Eqx \"[0-9a-f]{32}\" /etc/machine-id"'
code=$(app 'orca-serve --pair desktop' 2>/dev/null | grep -o 'orca://pair?code=[A-Za-z0-9_=-]*')
app "HOME=$CLIENT orca environment add --name self --pairing-code '$code'" >/dev/null 2>&1
check "a client pairs" 'within 120 connected'
# Using the offer restarts the runtime supervised; register once it's back.
within 60 supervised && within 120 connected
check "the client registers a repo" 'within 60 "add_repo && has_repo"'

machine_id=$(app 'cat /etc/machine-id')
keypair=$(app 'sha256sum ~/.config/orca/orca-e2ee-keypair.json')
sealing=$(app 'ls ~/.orca/orcad-secret-store-*.json')
install=$(app "stat -c %i $RR/\$(readlink $RR/current)")
app 'touch ~/.before-rebuild'
old=$id

# --build-no-cache: the feature's layer, and the machine id its packages
# generate, are built again.
echo "devcontainer up --remove-existing-container --build-no-cache"
$CLI up --workspace-folder "$W/app" --remove-existing-container --build-no-cache >"$W/up2.json" 2>"$W/up2.log"
rc=$?
id=$(grep -o '"containerId":"[^"]*"' "$W/up2.json" | head -1 | cut -d'"' -f4)
check "the rebuild succeeds, in a new container" '[ "$rc" = 0 ] && [ -n "$id" ] && [ "$id" != "$old" ]'
[ -n "$id" ] || { tail -30 "$W/up2.log"; exit 1; }
check "with a new HOME" 'app "[ ! -e ~/.before-rebuild ]"'
check "the runtime comes back up" 'within 120 "app \"(exec 3<>/dev/tcp/127.0.0.1/6768) 2>/dev/null\""'
check "supervised, since a device has paired" 'within 30 supervised'
check "the rebuilt image has a machine id of its own" \
  '[ "$(docker run --rm --entrypoint cat "$(docker inspect -f "{{.Image}}" "$id")" /var/lib/orca-feature/machine-id)" != "$machine_id" ]'
check "but /etc/machine-id is the same" '[ "$(app "cat /etc/machine-id")" = "$machine_id" ]'
check "the same E2EE keypair" '[ "$(app "sha256sum ~/.config/orca/orca-e2ee-keypair.json")" = "$keypair" ]'
check "the same credential key, which still opens" \
  '[ "$(app "ls ~/.orca/orcad-secret-store-*.json")" = "$sealing" ] && ! app "grep -q \"cannot unseal\" ~/orca-serve.log"'
check "the runtime isn't downloaded again" \
  '[ "$(app "stat -c %i $RR/\$(readlink $RR/current)")" = "$install" ] && ! grep -q "orca-install: downloading" "$W/up2.log"'
check "the client connects without pairing again" 'within 120 connected'
check "its repo is still registered" 'has_repo'
check "orca-serve --pair still makes an offer" \
  'app "orca-serve --pair desktop" 2>/dev/null | grep -q "^{\"value\":\"orca://pair?code="'

[ "$fail" = 0 ] || tail -30 "$W/up.log" "$W/up2.log"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
