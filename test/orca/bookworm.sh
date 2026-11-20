#!/bin/bash
set -e
source dev-container-features-test-lib

# Debian's package script calls adduser on the existing account. An
# out-of-range service UID makes this fail even when the name exists.
check "Bookworm accepts the messagebus account" adduser --system --quiet --group --home /nonexistent --no-create-home messagebus
for user in messagebus systemd-network; do
  check "$user leaves the high system IDs free" test "$(id -u "$user")" -le 899
done
reportResults
