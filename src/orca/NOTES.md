## How it works

Orca isn't baked into the image. On every container start, `orca-serve` (the
feature's `postStartCommand`):

1. Installs or updates Orca in `~/.local/share/orca-runtime/<version>`, verified
   against the release's sha512, with `current` pointing at the active one. It
   tracks the latest release, which is what the desktop app auto-updates to, so
   a new Orca release takes a restart rather than an image rebuild.
2. Starts `orca serve`, in pairing mode or supervised (see Pairing).

Updates only take effect while nothing is serving. One found while the runtime
is up is staged and taken on the next start, so the server and the CLI agents
call are always the same build. If GitHub can't be reached, or a download fails
its checksum, the installed version keeps serving. Downgrades are refused unless
`ORCA_ALLOW_DOWNGRADE=1`, because newer builds migrate profile state that older
ones can't read. The two newest versions are kept: current plus one to roll back
to, at about 800 MB each.

The feature also:

- sets `init: true`. **This is required, not optional.** orcad's instance lock
  treats an unreaped zombie orcad as still alive, so without an init the runtime
  can never restart after orcad dies, and `--supervise` gives up after six tries.
- installs the shared libraries and Xvfb Orca needs on slim Debian and Ubuntu
  images, choosing the `t64` package names where they apply
- puts `orca` and `orca-ide` on PATH for agents
- installs the `orca-cli` and `orchestration` Orca skills for Claude Code and
  Codex whenever the active version changes. This uses `npx`, so the container
  needs Node (for example the `node` feature); without it the step is skipped and
  retried on the next start.

## Pairing

A supervised server writing to a log redacts the pairing URL on purpose, so a
log never holds a live bearer offer. `orca-serve` therefore starts in **pairing
mode** (unsupervised, offer in `~/orca-serve.log`) until some device has
connected, and supervised on every start after that.

From the desktop:

```bash
code=$(ssh <user>@<host> "grep -o 'orca://pair?code=[^ ]*' ~/orca-serve.log | tail -1")
orca environment add --name <name> --pairing-code "$code"
ssh <user>@<host> orca-serve --restart        # now supervised
```

The code is a bearer secret. Pairing mode doesn't restart a crashed server, so
restart into supervised mode straight after pairing.

- **Phone:** after the desktop is paired, run `ORCA_MOBILE_PAIRING=1 orca-serve --restart`,
  scan the QR in `~/orca-serve.log`, then `orca-serve --restart`. The mobile and
  desktop offers are one or the other, and existing pairings keep working.
- **Another desktop:** `ORCA_PAIRING=1 orca-serve --restart`.

## Restarting

`orca-serve --restart` stops the runtime (TERM, then KILL after 15 s) and starts
it again, taking any staged update. It kills running agents. Use it rather than
`pkill -f <path>` over ssh: that pattern is on the ssh shell's own command line,
so it kills your session too.

## Runtime overrides

Environment variables override the options at runtime:

| Variable | |
|---|---|
| `ORCA_VERSION` | Version to run (empty or `latest` tracks the latest release) |
| `ORCA_SERVE_PORT` | Port |
| `ORCA_PAIRING_ADDRESS` | Advertised address |
| `ORCA_ALLOW_DOWNGRADE=1` | Allow moving to an older version |
| `ORCA_PAIRING=1` / `ORCA_MOBILE_PAIRING=1` | Start in pairing mode |

## Foreman environments

Leave `pairingAddress` empty: the runtime advertises `TS_HOSTNAME`, the
environment's tailnet name, and Foreman's userspace tailscaled delivers tailnet
connections to the runtime's port. Use one port (the default 6768) everywhere,
since each environment has its own tailnet address. If a client can't resolve
short MagicDNS names, set `pairingAddress` to the `<slug>.<tailnet>.ts.net` FQDN.

## Known limits

- **No phone push notifications from a headless runtime** (stablyai/orca#24932).
  In-app status and desktop notifications work.
- **Debian and Ubuntu images only** (apt).
- **Per-terminal memory caps** (`ORCA_TERMINAL_MEMORY_MAX`) need systemd, which
  containers don't have. Use container memory limits.
