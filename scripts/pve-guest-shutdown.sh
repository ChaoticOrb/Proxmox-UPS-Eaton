#!/usr/bin/env bash
#
# pve-guest-shutdown.sh
#
# Invoked by upsmon (as SHUTDOWNCMD, see /etc/nut/upsmon.conf) when the Eaton
# 3S UPS reaches a critical battery state. Attempts a graceful shutdown of
# all running VMs and LXC containers within a bounded time budget, force-stops
# anything still up after that, then powers off the Proxmox host.
#
# Not meant to be run interactively, but safe to run by hand for testing:
#   pve-guest-shutdown.sh --dry-run

set -uo pipefail

LOCK_FILE="/run/pve-guest-shutdown.lock"
GUEST_TIMEOUT=60   # seconds given to each guest for a graceful shutdown
MAX_WAIT=90        # hard cap before force-stopping remaining guests
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

log "Critical battery event received - beginning graceful guest shutdown."

pids=()

if command -v qm >/dev/null 2>&1; then
  while read -r vmid _rest; do
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    log "Shutting down VM ${vmid}..."
    run qm shutdown "$vmid" --timeout "$GUEST_TIMEOUT" --skiplock &
    pids+=($!)
  done < <(qm list 2>/dev/null | awk '$3=="running"{print $1, $3}')
fi

if command -v pct >/dev/null 2>&1; then
  while read -r vmid status _rest; do
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    [[ "$status" == "running" ]] || continue
    log "Shutting down container ${vmid}..."
    run pct shutdown "$vmid" --timeout "$GUEST_TIMEOUT" &
    pids+=($!)
  done < <(pct list 2>/dev/null | tail -n +2)
fi

if [[ ${#pids[@]} -gt 0 ]]; then
  log "Waiting up to ${MAX_WAIT}s for ${#pids[@]} guest(s) to shut down..."
  waited=0
  while [[ $waited -lt $MAX_WAIT ]]; do
    alive=0
    for pid in "${pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [[ $alive -eq 0 ]] && break
    sleep 2
    waited=$((waited + 2))
  done
fi

# Force-stop anything still running after the grace period.
if command -v qm >/dev/null 2>&1; then
  while read -r vmid _rest; do
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    log "VM ${vmid} still running after grace period - forcing stop."
    run qm stop "$vmid" --skiplock
  done < <(qm list 2>/dev/null | awk '$3=="running"{print $1, $3}')
fi

if command -v pct >/dev/null 2>&1; then
  while read -r vmid status _rest; do
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    [[ "$status" == "running" ]] || continue
    log "Container ${vmid} still running after grace period - forcing stop."
    run pct stop "$vmid"
  done < <(pct list 2>/dev/null | tail -n +2)
fi

log "All guests handled. Powering off host."
run /sbin/shutdown -h +0 "UPS battery critical - all guests stopped, powering off"
