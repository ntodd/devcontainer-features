#!/bin/bash
# The orca feature with every option set: a pinned version, a non-default port
# and an explicit pairing address.
set +e
source dev-container-features-test-lib

RR="$HOME/.local/share/orca-runtime"
PORT=6800

up() {
  for _ in $(seq 1 90); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

(exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || orca-serve
check "serves on the port option" up
check "installs the pinned version" bash -c "[ \"\$(basename \"\$(readlink '$RR/current')\")\" = 1.4.229 ]"
check "advertises the pairing address option" bash -c \
  "grep -o 'orca://pair?code=[^ ]*' ~/orca-serve.log | head -1 | sed 's/.*code=//' | tr '_-' '/+' |
   { read -r c; while [ \$(( \${#c} % 4 )) -ne 0 ]; do c=\"\$c=\"; done; printf '%s' \"\$c\"; } |
   base64 -d 2>/dev/null | grep -q 'orca-test.example:6800'"

reportResults
