#!/bin/sh
# Foreman's connect hook for Orca, installed as
# /usr/local/share/foreman/connect.d/orca. Foreman lists a hook's actions on
# the environment's page (`describe`) and shows what `run <action>` prints:
# here, a pairing offer for another Orca client, from orca-serve --pair.
# Outside Foreman it does nothing.
set -eu

case "${1:-}" in
  describe)
    cat <<'JSON'
{"label":"Orca","actions":[{"id":"desktop","label":"Pair a desktop","confirm":"Orca restarts to make a pairing offer, which stops its running agents. Paired clients reconnect."},{"id":"mobile","label":"Pair a phone","confirm":"Orca restarts to make a pairing offer, which stops its running agents. Paired clients reconnect."}]}
JSON
    ;;
  run)
    case "${2:-}" in
      desktop | mobile)
        # Foreman shows none of a failed run's output, which could hold the
        # offer, except an {"error"} last line. orca-serve's stderr never
        # holds the offer, so its last line is the explanation.
        err=$(mktemp)
        trap 'rm -f "$err"' EXIT
        orca-serve --pair "$2" 2>"$err" && exit 0
        why=$(grep -v '^[[:space:]]*$' "$err" | tail -n 1 | tr -d '"\\[:cntrl:]' | cut -c1-280)
        printf '{"error":"%s"}\n' "${why:-orca-serve --pair failed}"
        exit 1
        ;;
      *) echo "unknown action: ${2:-}" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "usage: $0 describe | run desktop|mobile" >&2
    exit 2
    ;;
esac
