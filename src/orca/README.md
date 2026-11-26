
# Orca runtime (orca)

Runs the container's own headless Orca runtime (orca serve), installing and updating Orca on every start, so a new Orca release takes a restart rather than an image rebuild. Its pairings, repos, sessions and install are kept in a volume, so they survive a rebuild.

## Example Usage

```json
"features": {
    "ghcr.io/ntodd/devcontainer-features/orca:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | Orca version to run. 'latest' tracks GitHub releases, which is what the desktop app auto-updates to; pin one (say 1.4.229) to hold it. ORCA_VERSION overrides it at runtime. | string | latest |
| port | Port the runtime listens on inside the container. ORCA_SERVE_PORT overrides it at runtime. | string | 6768 |
| pairingAddress | Address clients reach the runtime at, advertised in pairing offers. Empty uses TS_HOSTNAME (a Foreman environment's tailnet name), else 127.0.0.1. ORCA_PAIRING_ADDRESS overrides it at runtime. | string | - |

## How it works

Orca isn't baked into the image. On every container start, `orca-serve` (the
feature's `postStartCommand`):

1. Installs or updates Orca in `~/.local/share/orca-runtime/<version>` (in the
   feature's volume, see State and rebuilds), verified against the release's
   sha512, with `current` pointing at the active one. It tracks the latest
   release, which is what the desktop app auto-updates to, so a new Orca
   release takes a restart rather than an image rebuild.
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

In a Foreman environment, the environment's page has **Pair a desktop** and
**Pair a phone** buttons (see below). Elsewhere, ask for an offer over SSH:

```bash
code=$(ssh <user>@<host> orca-serve --pair desktop | grep -o 'orca://pair?code=[^"]*')
orca environment add --name <name> --pairing-code "$code"
```

`orca-serve --pair desktop|mobile` restarts the runtime into pairing mode, which
stops its running agents, and prints the offer as one line of JSON on stdout
(`{"value": "orca://pair?code=…", "qr": false, "note": "…"}`; `qr` is true for
a phone, whose app scans the same URL as a QR code). Existing pairings keep
working, and paired clients reconnect. It leaves a watcher behind that restarts
the runtime supervised as soon as the offer is used, since pairing mode doesn't
restart a crashed server. An offer that's never used leaves the runtime in
pairing mode until it next restarts: the watcher gives up after 15 minutes
(`ORCA_PAIRING_WATCH_SECONDS`) rather than kill agents started since. Until an
offer is used, asking again gets the same one, so unused offers don't pile up.

The code is a bearer secret. `--pair` prints it to stdout only; the runtime
also writes it to `~/orca-serve.log` (mode 0600) while in pairing mode. One
`orca-serve` start, restart or pairing runs at a time, and a restart by hand
cancels a pending watcher.

### Foreman

The feature installs a Foreman connect hook at
`/usr/local/share/foreman/connect.d/orca`. Foreman finds it when the environment
comes up and lists its actions on the environment's page; running one shows the
offer, with a QR code for a phone, to the environment's owner. Outside Foreman
nothing reads it.

## Restarting

`orca-serve --restart` stops the runtime (TERM, then KILL after 15 s) and starts
it again, taking any staged update. It kills running agents. Use it rather than
`pkill -f <path>` over ssh: that pattern is on the ssh shell's own command line,
so it kills your session too.

## State and rebuilds

A rebuild discards `$HOME` unless the repo mounts it as a volume, and with it
Orca's keypair and paired devices: every client would have to pair again. So
the feature mounts a volume of its own per environment,
`orca-state-${devcontainerId}`, at `/var/lib/orca-feature`, and `orca-serve`
keeps Orca's state there, in a directory only the remote user can open (0700),
with links at the paths Orca and its CLI use:

| In `/var/lib/orca-feature` | Linked from | |
|---|---|---|
| `<user>/config` | `~/.config/orca` | Orca's profile: the E2EE keypair, paired devices, the runtime's id, repos, worktrees and sessions |
| `<user>/data` | `~/.orca` | Orca's credential directory |
| `<user>/runtime` | `~/.local/share/orca-runtime` | The runtime install, so a rebuild doesn't download it again |
| `machine-id` | `/etc/machine-id` | See below |

Orca is given the profile's real path (`ORCA_USER_DATA_PATH`); it has no such
setting for `~/.orca`, which is why that one is a link. The mount point lets
anyone create in it, like `/tmp`, because the remote user's uid can change
after the image is built (`updateRemoteUserUID`).

After a rebuild a paired client reconnects without pairing again, and its
repos and sessions are still there. A device has connected, so the runtime
starts supervised and prints no offer; `orca-serve --pair` makes one as usual.
Rebuilding keeps the volume; removing the environment (`docker compose down
-v`, or destroying it in Foreman) removes it.

**Machine ID.** Orca seals the credentials it saves (integration API keys and
tokens) with a key mixed with `/etc/machine-id`. The feature's packages
generate that id in its image layer, so it would change whenever the layer is
rebuilt (a new feature version, a pruned build cache), and saved credentials
would no longer open. The feature keeps the id at
`/var/lib/orca-feature/machine-id` instead, with `/etc/machine-id` a link to
it: a new volume starts with the image's copy and keeps it from then on.

**Moving in.** The first start with the volume moves state already in `$HOME`
into it once, so a repo whose `$HOME` is a volume keeps its pairings. If the
volume already has a profile, the volume's wins, and the one in `$HOME` is set
aside as `~/.config/orca.before-volume-<time>`; `orca-serve` says where.

**Without the volume.** If nothing is mounted at `/var/lib/orca-feature`, or
the remote user can't make its directory there, `orca-serve` says so in one
line and keeps the state in `$HOME`, as before.

**Stale state.** A rebuilt container finds whatever the last one's runtime
left in the profile. When nothing is serving, `orca-serve` treats all of it as
stale: it kills orphaned runtime processes, removes the `Singleton*` files,
`orcad.lock` and `o-*.sock`, and starts the supervised runtime with `--force`,
so the supervisor's give-up record (6 failures in 15 minutes) from the old
container doesn't stop the new one.

## Runtime overrides

Environment variables override the options at runtime:

| Variable | |
|---|---|
| `ORCA_VERSION` | Version to run (empty or `latest` tracks the latest release) |
| `ORCA_SERVE_PORT` | Port |
| `ORCA_PAIRING_ADDRESS` | Advertised address |
| `ORCA_ALLOW_DOWNGRADE=1` | Allow moving to an older version |
| `ORCA_PAIRING=1` / `ORCA_MOBILE_PAIRING=1` | Start in pairing mode |
| `ORCA_STATE_VOLUME` | Where the state volume is mounted; empty keeps Orca's state in `$HOME` |

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


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/ntodd/devcontainer-features/blob/main/src/orca/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
