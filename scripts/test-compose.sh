#!/usr/bin/env bash
# Checks the orca feature on a compose-based devcontainer, which
# `devcontainer features test` can't build. A feature's `init` and
# `postStartCommand` reach a compose service only through the override file the
# devcontainer CLI generates, and the orca runtime can't recover without init.
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
    environment:
      TS_HOSTNAME: orca-compose-check
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

[ "$fail" = 0 ] || tail -30 "$W/up.log"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
