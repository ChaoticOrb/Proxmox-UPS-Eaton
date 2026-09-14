#!/usr/bin/env bash
#
# pve-guest-shutdown.sh
#
# Invoked by upsmon (as SHUTDOWNCMD, see /etc/nut/upsmon.conf) when the Eaton
# 3S UPS reaches a critical battery state.
#
# Proxmox VE already stops every running VM/LXC on any normal host shutdown
# on its own, via pve-guests.service (which runs `pvesh ... stopall`) as
# part of the standard systemd shutdown sequence - that happens with or
# without this script. What this script adds is an explicit, bounded
# timeout and a forced stop after it: left to your installed PVE version's
# own defaults, that stop can take much longer than a UPS on a dying battery
# can afford, or - on some versions - have no timeout at all. This pins it
# down instead of trusting the default, then powers the host off.
#
# Not meant to be run interactively, but safe to run by hand for testing:
#   pve-guest-shutdown.sh --dry-run

set -uo pipefail

LOCK_FILE="/run/pve-guest-shutdown.lock"
GUEST_TIMEOUT=60   # seconds given to each guest for a graceful shutdown
DRY_RUN=0

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { logger -t pve-guest-shutdown "$*"; echo "[pve-guest-shutdown] $*"; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

# Prevent overlapping runs if upsmon fires SHUTDOWNCMD more than once.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another shutdown is already in progress; exiting."
  exit 0
fi

log "Critical battery event received."

if command -v pvesh >/dev/null 2>&1; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log "Currently running guests (informational only - stopall decides what to stop):"
    command -v qm  >/dev/null 2>&1 && qm list  2>/dev/null | awk 'NR==1 || $3=="running"' | sed 's/^/[pve-guest-shutdown]   VM  /'
    command -v pct >/dev/null 2>&1 && pct list 2>/dev/null | awk 'NR==1 || $2=="running"' | sed 's/^/[pve-guest-shutdown]   CT  /'
  fi
  log "Stopping all running guests (pvesh stopall, ${GUEST_TIMEOUT}s timeout, then force-stop)."
  run pvesh --nooutput create /nodes/localhost/stopall --timeout "$GUEST_TIMEOUT" --force-stop 1
else
  log "pvesh not found (not running on a Proxmox VE node?) - skipping guest shutdown."
fi

log "Powering off host."
run /sbin/shutdown -h +0 "UPS battery critical - guests stopped, powering off"
