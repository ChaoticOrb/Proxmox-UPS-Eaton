# Proxmox-UPS-Eaton

A script for installing and configuring [NUT (Network UPS Tools)](https://networkupstools.org/)
on a Proxmox VE node with a USB-connected Eaton 3S UPS.

The Eaton 3S is USB-HID compliant, so NUT's `usbhid-ups` driver auto-detects
it with `port = auto` — no vendor/product IDs need to be hardcoded.

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
  critical battery event, gracefully shuts down all running VMs and LXC
  containers (with a bounded grace period, then a forced stop) before
  powering off the host.
- Backs up any existing NUT config files it touches before overwriting them,
  so it's safe to re-run.

## Usage

Run as root on the Proxmox node with the UPS connected via USB:

```sh
./install-nut-eaton.sh
```

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
| `--no-guest-shutdown` | Skip installing the VM/LXC graceful-shutdown helper | off |
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

## Verifying the install

```sh
upsc eaton3s@localhost
```

This should print battery charge, status, and other data reported by the
UPS. If it doesn't, check driver logs:

```sh
journalctl -u nut-server -u 'nut-driver@eaton3s' -n 50
```

## Testing the shutdown path

Pull the UPS's power cord and let the battery drain to a critical level (or
temporarily lower `upsmon.conf`'s thresholds via `upssched`/`ups.conf` for a
faster test in a maintenance window). You can also dry-run the guest
shutdown logic without actually stopping anything:

```sh
/usr/local/bin/pve-guest-shutdown.sh --dry-run
```
