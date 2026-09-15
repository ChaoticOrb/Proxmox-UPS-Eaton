# Proxmox-UPS-Eaton

A script for installing and configuring [NUT (Network UPS Tools)](https://networkupstools.org/)
on a Proxmox VE node with a USB-connected Eaton 3S UPS.

The Eaton 3S is USB-HID compliant, so NUT's `usbhid-ups` driver auto-detects
it with `port = auto` — no vendor/product IDs need to be hardcoded.

> [!WARNING]
> **Piping a script straight from the internet into `bash` runs it with root
> privileges before you've looked at a single line of it.** That's true of
> the one-liner below, and of any `curl | bash` command from any source, not
> just this repo. Read the script first — either open
> [`install-nut-eaton.sh`](install-nut-eaton.sh) and
> [`scripts/pve-guest-shutdown.sh`](scripts/pve-guest-shutdown.sh) on GitHub,
> or download before executing (see below) — before you trust it with root
> on your Proxmox node.

## Quick install

Review the script first (see the warning above), then, as root on the
Proxmox node with the UPS plugged in:

```sh
curl -fsSL https://raw.githubusercontent.com/ChaoticOrb/Proxmox-UPS-Eaton/main/install-nut-eaton.sh | bash
```

To pass flags (e.g. to also set up the [Home Assistant read-only
account](#home-assistant-integration)), use `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/ChaoticOrb/Proxmox-UPS-Eaton/main/install-nut-eaton.sh | bash -s -- --ha-user
```

Not running as root already? Pipe into `sudo bash` instead of `bash`.

To actually read the script before it runs, rather than trusting it sight
unseen, download it first and inspect it, then run the local copy:

```sh
curl -fsSL https://raw.githubusercontent.com/ChaoticOrb/Proxmox-UPS-Eaton/main/install-nut-eaton.sh -o install-nut-eaton.sh
less install-nut-eaton.sh   # read it
chmod +x install-nut-eaton.sh
sudo ./install-nut-eaton.sh
```

When run this way (no local git checkout), the script also fetches
`scripts/pve-guest-shutdown.sh` from this repo on demand for the same
reason; `git clone`-ing the repo instead (see below) avoids any of that
happening at install time.

## What it does

- Installs the `nut` package.
- Configures NUT in **standalone** mode (driver, server, and monitor all on
  this one node) for the UPS.
- Creates an `upsd` user for `upsmon` to authenticate with, and defaults to
  listening on `localhost` only (pass `--listen-lan` to also listen on all
  interfaces if another host needs to poll this UPS over the network).
- Optionally (`--ha-user`) creates a second `upsd` account for Home
  Assistant's NUT integration, with no monitor/control privileges — see
  [Home Assistant integration](#home-assistant-integration) below.
- Installs a shutdown helper (`scripts/pve-guest-shutdown.sh`) that, on a
  critical battery event, stops all running VMs and LXC containers with an
  explicit, bounded timeout before powering off the host — see [Why the
  shutdown helper exists](#why-the-shutdown-helper-exists) below for why
  this isn't just Proxmox's own default shutdown behavior.
- Sets up email alerting (`/etc/nut/notify.sh`) for UPS events — on
  battery, low battery, comms lost, etc — see [Email
  alerting](#email-alerting) below, including a critical warning about how
  *not* to test it.
- Reloads and retriggers udev rules after installing the `nut` package, so
  a UPS that was already plugged in before this ran gets its USB
  permissions fixed too, not just ones plugged in afterward.
- Backs up any existing NUT config files it touches before overwriting them
  (a per-file `.bak-<timestamp>`), and additionally snapshots the whole of
  `/etc/nut` to `/root/nut-config-backup-<timestamp>.tar.gz` before making
  any changes at all — so it's safe to re-run.

## Usage

The most reviewable way to run this: clone the repo, read the code, then run
your own local copy as root on the Proxmox node with the UPS connected via
USB.

```sh
git clone https://github.com/ChaoticOrb/Proxmox-UPS-Eaton.git
cd Proxmox-UPS-Eaton
sudo ./install-nut-eaton.sh
```

(See [Quick install](#quick-install) above for a one-line `curl | bash`
alternative, and the warning there about the risk of running any script that
way without reading it first.)

Options:

| Flag | Description | Default |
|---|---|---|
| `--ups-name NAME` | Name used for the UPS in `ups.conf` | `eaton3s` |
| `--admin-user USER` | `upsd`/`upsmon` username | `upsmon` |
| `--admin-password PASS` | Password for `--admin-user` (skips the prompt) | prompted interactively |
| `--ha-user` | Create a read-only account for Home Assistant | off |
| `--ha-user-name NAME` | Home Assistant account name (implies `--ha-user`) | `homeassistant` |
| `--ha-password PASS` | Password for the Home Assistant account (skips the prompt, implies `--ha-user`) | prompted interactively |
| `--generate-password` | Generate random passwords instead of prompting | off |
| `--listen-lan` | Also listen on all interfaces, not just localhost (implied by `--ha-user`) | off |
| `--no-guest-shutdown` | Skip the timeout helper (Proxmox's own default guest-stop still applies) | off |
| `--no-notify` | Skip setting up email alerting on UPS events | off |
| `--notify-email ADDR` | Local mail recipient for alerts (implies alerting is on) | `root` |
| `--uninstall` | Stop services and remove the installed shutdown helper | — |
| `-y`, `--yes` | Don't prompt for confirmation | off |
| `-h`, `--help` | Show help | — |

## Home Assistant integration

```sh
./install-nut-eaton.sh --ha-user
```

This creates a second `upsd.users` account (default name `homeassistant`)
with no `upsmon` directive and no `actions`/`instcmds` — it can authenticate
but can't become the monitoring master, issue instant commands, or change
any UPS setting. Since Home Assistant runs in its own VM (not on the
Proxmox host's loopback), this also switches on `--listen-lan` automatically
so `upsd` is reachable from the VM.

In Home Assistant, add the **NUT** integration pointing at the Proxmox
node's IP, port `3493`, UPS name as set by `--ups-name` (default `eaton3s`),
and the account name/password printed at the end of the install.

**Important caveat:** NUT's wire protocol does not actually gate status
reads (`GET VAR` / `LIST VAR` — what both `upsc` and Home Assistant's
integration use) behind authentication. Any client that can reach `upsd`'s
listening address can read UPS status whether or not it supplies a
username/password. The `--ha-user` account's real value is that it *can't
control anything* even if its credentials leak, not that it restricts who
can read status. If you want to actually restrict which hosts can reach
port 3493, do it with a firewall rule (e.g. the Proxmox/Datacenter
firewall) scoped to the Home Assistant VM's IP — `upsd` itself no longer
does per-host access control.

## Why the shutdown helper exists

Proxmox VE already stops every running VM/LXC on **any** host shutdown, with
no extra configuration: `pve-guests.service` is enabled by default on every
install, and its stop action (`pvesh ... stopall`) runs as part of the
normal systemd shutdown sequence — triggered by the GUI, `shutdown -h now`,
and therefore by NUT's default `SHUTDOWNCMD` too. If all you wanted was "try
to shut guests down cleanly before the host goes off," you don't need this
script's helper at all; `--no-guest-shutdown` gets you a plain
`shutdown -h +0`, and Proxmox's own mechanism still runs.

What the helper actually adds is a **bounded, explicit timeout**. Left to
its own defaults, `stopall`'s per-guest timeout and force-stop behavior
depend on your installed Proxmox version — and there's a documented history
of that default being effectively unbounded on some versions. That's fine
for a normal reboot, but not for a UPS with a couple of minutes of runtime
left: an unresponsive guest could leave the host still waiting to shut down
when the battery actually dies, which is worse than not having a shutdown
trigger at all. The helper just calls Proxmox's own `stopall` task with an
explicit `--timeout`/`--force-stop`, rather than trusting whatever your PVE
version defaults to.

One thing I haven't been able to verify (Proxmox's own docs and forum were
unreachable from the environment this was built in): whether `stopall`
stops guests in parallel or one at a time when you haven't configured an
explicit "Start/Shutdown order" on them (the common case). If it's
sequential, the worst-case total time scales with your guest count — with
close to a dozen VMs/LXCs, that's worth testing for yourself (see below)
rather than assuming.

## Email alerting

By default the install writes `/etc/nut/notify.sh`, which mails
`--notify-email` (default `root`) on UPS state-change events — power lost,
power restored, low battery, forced shutdown, communication lost/restored,
etc. `--no-notify` skips this entirely.

This assumes root's local mail already relays somewhere you'll actually see
it. The script has no way to confirm that for you — check it yourself:

```sh
echo test | mail -s test root
```

If that doesn't arrive anywhere, fix local mail relay first (or replace the
one line in `/etc/nut/notify.sh` with something else — e.g. a `curl` to a
push service — the rest of the wiring, `NOTIFYCMD`/`NOTIFYFLAG` in
`upsmon.conf`, doesn't care what the script does).

### ⚠️ Never test with `upsmon -c fsd`

`upsmon -c fsd` is **not a safe way to test this.** On a `primary` instance
(this one) it sets the real forced-shutdown flag, which — combined with
`SHUTDOWNCMD` — triggers an actual shutdown of the host, and of the UPS
itself via the driver. This has actually happened during this project's own
manual testing and caused an unplanned reboot of the node it was run on.

To test the alert path itself, safely, without touching shutdown logic at
all:

```sh
NOTIFYTYPE=ONBATT /etc/nut/notify.sh "test message"
```

Confirm the email arrives with subject `NUT: ONBATT on <hostname>`.

## Verifying the install

```sh
upsc eaton3s@localhost
```

This should print battery charge, status, and other data reported by the
UPS. If it doesn't:

```sh
systemctl status nut-driver@eaton3s
journalctl -u nut-driver@eaton3s -n 50
```

The driver runs as its own systemd unit, separate from `nut-server` and
`nut-monitor` — restarting those two doesn't start or restart it, and the
install script checks it explicitly for this reason. The most common
failure at this stage is a USB permissions error in that log
(`insufficient permissions on everything` or similar): the `nut` package's
udev rule only takes effect for USB devices enumerated *after* the rule
exists on disk, so a UPS that was already plugged in before you first ran
this script can still show up as root-owned rather than group `nut`. The
script reloads and retriggers udev rules on every run to cover this, but if
it still doesn't take, unplug and re-plug the UPS (or reboot) and try
again.

## Testing the shutdown path

Pull the UPS's power cord and let the battery drain to a critical level (or
temporarily lower `upsmon.conf`'s thresholds via `upssched`/`ups.conf` for a
faster test in a maintenance window). You can also preview what the helper
would do without actually stopping anything or powering off:

```sh
/usr/local/bin/pve-guest-shutdown.sh --dry-run
```

This lists your currently-running guests and logs the exact `pvesh`/`shutdown`
commands it would run, without executing them. It won't tell you how long a
*real* run would take with all your guests stopping at once, though — for
that, with everything backed up and in a maintenance window, it's worth
timing a real (non-dry-run) invocation once, so `GUEST_TIMEOUT` in the
script (default 60s) is a number you've actually validated against your own
guest count, not just trusted.
