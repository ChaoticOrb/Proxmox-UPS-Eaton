#!/usr/bin/env bash
#
# install-nut-eaton.sh
#
# Installs and configures Network UPS Tools (NUT) on a Proxmox VE node for a
# USB-connected Eaton 3S UPS, in standalone mode. On a critical battery
# event, upsmon triggers a plain host shutdown; Proxmox's own
# pve-guests.service stops all running VMs/LXCs as part of that automatically
# - no extra script needed for that. Also sets up email alerting on UPS
# events (on battery, low battery, comms lost, etc).
#
# Run with --help (or see usage() below) for the full option list.

set -euo pipefail

UPS_NAME="eaton3s"
ADMIN_USER="upsmon"
ADMIN_PASSWORD=""
HA_USER_ENABLED=0
HA_USER_NAME="homeassistant"
HA_PASSWORD=""
LISTEN_LAN=0
INSTALL_NOTIFY=1
NOTIFY_EMAIL="root"
ASSUME_YES=0
UNINSTALL=0

NUT_ETC="/etc/nut"
EATON_USB_VENDOR="0463"

log()  { echo "[nut-setup] $*"; }
warn() { echo "[nut-setup] WARNING: $*" >&2; }
die()  { echo "[nut-setup] ERROR: $*" >&2; exit 1; }

# Self-contained (doesn't read "$0"): under `curl | bash -s -- --help`, $0 is
# just "bash", not this file, so re-parsing our own source for the help text
# would silently fail there.
usage() {
  cat <<'EOF'
install-nut-eaton.sh

Installs and configures Network UPS Tools (NUT) on a Proxmox VE node for a
USB-connected Eaton 3S UPS, in standalone mode. On a critical battery event,
upsmon triggers a plain host shutdown; Proxmox's own pve-guests.service
stops all running VMs/LXCs as part of that automatically - no extra script
needed for that. Also sets up email alerting on UPS events.

Usage:
  ./install-nut-eaton.sh [options]

Options:
  --ups-name NAME       Name used for the UPS in ups.conf (default: eaton3s)
  --admin-user USER     upsd admin/monitoring username (default: upsmon)
  --admin-password PASS Password for --admin-user (default: randomly generated
                        and printed at the end - see below)
  --ha-user              Create a second, read-only upsd account for Home
                         Assistant's NUT integration (name: homeassistant)
  --ha-user-name NAME    Override the Home Assistant account name (must
                         differ from --admin-user)
  --ha-password PASS     Password for the Home Assistant account (default:
                         randomly generated and printed at the end)
  --listen-lan          Also listen on all interfaces (default: localhost only;
                         implied by --ha-user, since a VM isn't on loopback)
  --no-notify           Skip setting up email alerting on UPS events
  --notify-email ADDR    Local mail recipient for alerts (default: root)
  --uninstall           Remove the NUT config this script created and stop services
  -y, --yes             Do not prompt for confirmation
  -h, --help            Show this help text

Re-running this script is safe: existing config files are backed up with a
.bak-<timestamp> suffix before being rewritten, and a full snapshot of
/etc/nut is additionally saved to /root/nut-config-backup-<timestamp>.tar.gz
before anything is touched. Note that re-running without --admin-password/
--ha-password generates and sets a NEW random password each time - pass
them explicitly if you want re-runs to keep the same credentials.

Note on "read-only": NUT's protocol does not gate status reads (GET VAR /
LIST VAR - what upsc and the Home Assistant integration use) behind
authentication at all; any client that can reach upsd's LISTEN address can
read UPS status regardless of credentials. The --ha-user account can't
authenticate as a monitor primary or run control commands (SET/INSTCMD), so
it can't shut anything down or change UPS settings - but the real fence
around *who can read* is the LISTEN bind address plus your firewall, not
this password. See the README for a firewall recommendation.

Note on testing alerting: never run `upsmon -c fsd` to test this. On a
primary instance (which this is) it sets the real forced-shutdown flag and,
combined with SHUTDOWNCMD, actually shuts the host down. Use
`NOTIFYTYPE=ONBATT /etc/nut/notify.sh "test"` instead - see the README.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ups-name) UPS_NAME="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --ha-user) HA_USER_ENABLED=1; shift ;;
    --ha-user-name) HA_USER_ENABLED=1; HA_USER_NAME="$2"; shift 2 ;;
    --ha-password) HA_USER_ENABLED=1; HA_PASSWORD="$2"; shift 2 ;;
    --listen-lan) LISTEN_LAN=1; shift ;;
    --no-notify) INSTALL_NOTIFY=0; shift ;;
    --notify-email) INSTALL_NOTIFY=1; NOTIFY_EMAIL="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Must be run as root (use sudo)."
command -v apt-get >/dev/null 2>&1 || die "This script targets Debian/Proxmox (apt-get not found)."

if [[ $HA_USER_ENABLED -eq 1 && "$HA_USER_NAME" == "$ADMIN_USER" ]]; then
  die "--ha-user-name '${HA_USER_NAME}' is the same as --admin-user; upsd.users needs two distinct account names (pick a different --ha-user-name or --admin-user)."
fi

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -p "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)"
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local prompt="$1"
  if [[ ! -t 0 ]]; then
    # No terminal to ask on (e.g. running via `curl | bash`) - reading from
    # stdin here would consume bytes the shell still needs to parse the rest
    # of this piped script, corrupting execution. Proceed instead of hanging
    # or reading garbage; re-run with -y to make this explicit and silence
    # the warning, or Ctrl-C now to abort.
    warn "No terminal to confirm on; proceeding automatically (re-run with -y to silence this)."
    return 0
  fi
  read -r -p "${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Resolves a password into $1: an explicit value already supplied (e.g.
# --admin-password), or a random one. Never prompts - this script is meant
# to run unattended (including piped via `curl | bash`, where interactive
# input isn't safe to read at all - see confirm() above). Sets
# LAST_PASSWORD_GENERATED=1 when it had to generate one, so callers know
# whether it's safe/necessary to print the password back at the end.
resolve_password() {
  local outvar="$1" explicit="$2"
  if [[ -n "$explicit" ]]; then
    printf -v "$outvar" '%s' "$explicit"
    LAST_PASSWORD_GENERATED=0
  else
    printf -v "$outvar" '%s' "$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    LAST_PASSWORD_GENERATED=1
  fi
}

# ---------------------------------------------------------------------------
# Uninstall path
# ---------------------------------------------------------------------------
if [[ $UNINSTALL -eq 1 ]]; then
  log "Stopping NUT services..."
  systemctl stop nut-monitor.service nut-server.service nut-driver-enumerator.path 2>/dev/null || true
  systemctl disable nut-monitor.service nut-server.service 2>/dev/null || true
  if systemctl list-unit-files "nut-driver@*.service" >/dev/null 2>&1; then
    systemctl stop "nut-driver@${UPS_NAME}.service" 2>/dev/null || true
    systemctl disable "nut-driver@${UPS_NAME}.service" 2>/dev/null || true
  fi
  upsdrvctl stop 2>/dev/null || true
  rm -f /usr/local/bin/pve-guest-shutdown.sh
  log "NUT configuration left in place under ${NUT_ETC} (remove manually or 'apt purge nut' if desired)."
  log "Uninstall steps complete."
  exit 0
fi

if dpkg -l 2>/dev/null | grep -qE '^ii\s+nut\s'; then
  log "nut is already installed - this run will reconfigure it in place."
fi

# ---------------------------------------------------------------------------
# 1. Detect the UPS on USB (informational; usbhid-ups auto-detects at runtime)
# ---------------------------------------------------------------------------
if command -v lsusb >/dev/null 2>&1; then
  if lsusb | grep -qi "${EATON_USB_VENDOR}"; then
    log "Detected a USB device with Eaton's vendor ID (${EATON_USB_VENDOR}):"
    lsusb | grep -i "${EATON_USB_VENDOR}" | sed 's/^/[nut-setup]   /'
  else
    warn "No USB device with Eaton's vendor ID (${EATON_USB_VENDOR}) found."
    warn "Continuing anyway - plug in the UPS before starting the driver, or re-run later."
    if ! confirm "Continue installation without a detected UPS?"; then
      die "Aborted by user."
    fi
  fi
else
  warn "lsusb not found (usbutils not installed); skipping USB detection."
fi

# ---------------------------------------------------------------------------
# 2. Install packages
# ---------------------------------------------------------------------------
log "Installing nut and usbutils..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y nut usbutils >/dev/null

id nut >/dev/null 2>&1 || die "nut package installed but 'nut' system user is missing - aborting."

# ---------------------------------------------------------------------------
# 3. Reload/retrigger udev rules. The nut package ships a udev rule that
#    grants the 'nut' group access to known UPS USB IDs, but that only
#    applies to devices enumerated after the rule exists on disk - if the
#    UPS was already plugged in before this install, its device node can
#    still be root-only, which fails the driver with a permissions error
#    later. Cheap and harmless to always do.
# ---------------------------------------------------------------------------
log "Reloading udev rules and retriggering (covers a UPS that was already plugged in before this install)..."
udevadm control --reload-rules 2>/dev/null || warn "udevadm control --reload-rules failed - continuing."
udevadm trigger 2>/dev/null || warn "udevadm trigger failed - continuing."

# ---------------------------------------------------------------------------
# 4. Snapshot the whole of /etc/nut before this run's edits, in addition to
#    the per-file .bak-<timestamp> backups each step below takes.
# ---------------------------------------------------------------------------
if [[ -d "$NUT_ETC" ]]; then
  full_backup="/root/nut-config-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  log "Backing up ${NUT_ETC} to ${full_backup}..."
  tar czf "$full_backup" -C "$(dirname "$NUT_ETC")" "$(basename "$NUT_ETC")" 2>/dev/null \
    || warn "Full ${NUT_ETC} backup failed - continuing (the per-file .bak-<timestamp> backups below still apply)."
fi

# ---------------------------------------------------------------------------
# 5. Remove a guest-shutdown helper from an older version of this script, if
#    present. Proxmox's own pve-guests.service already stops all running
#    guests on any host shutdown (including the plain one SHUTDOWNCMD
#    triggers below) with no extra script needed - re-implementing that by
#    hand was more complexity than it was worth.
# ---------------------------------------------------------------------------
rm -f /usr/local/bin/pve-guest-shutdown.sh

# ---------------------------------------------------------------------------
# 6. notify.sh - mails NOTIFY_EMAIL on UPS state-change events (on battery,
#    low battery, forced shutdown, comms lost, etc). See upsmon.conf's
#    NOTIFYFLAG block (step 12) for which events trigger it. This assumes
#    root's local mail already relays somewhere reachable - verify that
#    independently (see README); this script has no way to confirm it.
# ---------------------------------------------------------------------------
if [[ $INSTALL_NOTIFY -eq 1 ]]; then
  log "Writing ${NUT_ETC}/notify.sh (mails ${NOTIFY_EMAIL} on UPS events)..."
  backup_file "${NUT_ETC}/notify.sh"
  cat > "${NUT_ETC}/notify.sh" <<EOF
#!/bin/sh
# Managed by install-nut-eaton.sh
echo "\$1" | mail -s "NUT: \$NOTIFYTYPE on \$(hostname)" ${NOTIFY_EMAIL}
EOF
fi

# ---------------------------------------------------------------------------
# 7. Determine passwords: explicit --admin-password/--ha-password if given,
#    otherwise randomly generated (never prompted - see resolve_password()
#    above) and printed at the end. If a read-only Home Assistant account
#    was requested, it needs the server reachable off-loopback (HA runs in
#    its own VM), so imply --listen-lan unless the user already set it.
# ---------------------------------------------------------------------------
resolve_password ADMIN_PASSWORD "$ADMIN_PASSWORD"
GENERATED_ADMIN_PASSWORD=$LAST_PASSWORD_GENERATED

if [[ $HA_USER_ENABLED -eq 1 ]]; then
  resolve_password HA_PASSWORD "$HA_PASSWORD"
  GENERATED_HA_PASSWORD=$LAST_PASSWORD_GENERATED

  if [[ $LISTEN_LAN -eq 0 ]]; then
    log "Home Assistant account requested - enabling --listen-lan so upsd is reachable from the HA VM."
    LISTEN_LAN=1
  fi
fi

# ---------------------------------------------------------------------------
# 8. nut.conf - standalone mode (this node runs driver + server + monitor)
# ---------------------------------------------------------------------------
log "Writing ${NUT_ETC}/nut.conf..."
backup_file "${NUT_ETC}/nut.conf"
cat > "${NUT_ETC}/nut.conf" <<EOF
MODE=standalone
EOF

# ---------------------------------------------------------------------------
# 9. ups.conf - the Eaton 3S is USB HID compliant; usbhid-ups auto-detects it
#    with port=auto, so no vendor/product ID needs to be hardcoded.
# ---------------------------------------------------------------------------
log "Writing ${NUT_ETC}/ups.conf (UPS name: ${UPS_NAME})..."
backup_file "${NUT_ETC}/ups.conf"
cat > "${NUT_ETC}/ups.conf" <<EOF
# Managed by install-nut-eaton.sh
maxretry = 3

[${UPS_NAME}]
    driver = usbhid-ups
    port = auto
    desc = "Eaton 3S UPS"
EOF

# ---------------------------------------------------------------------------
# 10. upsd.conf - who can connect to the data server
# ---------------------------------------------------------------------------
log "Writing ${NUT_ETC}/upsd.conf..."
backup_file "${NUT_ETC}/upsd.conf"
{
  echo "# Managed by install-nut-eaton.sh"
  echo "LISTEN 127.0.0.1 3493"
  echo "LISTEN ::1 3493"
  if [[ $LISTEN_LAN -eq 1 ]]; then
    echo "LISTEN 0.0.0.0 3493"
    echo "LISTEN :: 3493"
  fi
} > "${NUT_ETC}/upsd.conf"

if [[ $LISTEN_LAN -eq 1 ]]; then
  warn "upsd will listen on all interfaces (port 3493)."
  warn "Make sure your firewall restricts access to trusted hosts only."
fi

# ---------------------------------------------------------------------------
# 11. upsd.users - credentials for clients connecting to upsd
# ---------------------------------------------------------------------------
HA_USER_LOG_SUFFIX=""
[[ $HA_USER_ENABLED -eq 1 ]] && HA_USER_LOG_SUFFIX=", ${HA_USER_NAME}"
log "Writing ${NUT_ETC}/upsd.users (user: ${ADMIN_USER}${HA_USER_LOG_SUFFIX})..."
backup_file "${NUT_ETC}/upsd.users"
cat > "${NUT_ETC}/upsd.users" <<EOF
# Managed by install-nut-eaton.sh
[${ADMIN_USER}]
    password = ${ADMIN_PASSWORD}
    upsmon primary
EOF

if [[ $HA_USER_ENABLED -eq 1 ]]; then
  cat >> "${NUT_ETC}/upsd.users" <<EOF

# Read-only account for Home Assistant's NUT integration: no 'upsmon'
# directive and no actions/instcmds, so it cannot become monitor primary or
# run control commands. See the note at the top of this script re: NUT not
# gating status reads (GET VAR/LIST VAR) behind auth at all.
[${HA_USER_NAME}]
    password = ${HA_PASSWORD}
EOF
fi

# ---------------------------------------------------------------------------
# 12. upsmon.conf - local monitoring, shutdown trigger, and alerting
# ---------------------------------------------------------------------------
log "Writing ${NUT_ETC}/upsmon.conf..."
backup_file "${NUT_ETC}/upsmon.conf"
# Plain host shutdown - Proxmox's own pve-guests.service stops all running
# guests as part of any normal shutdown sequence, this included, with no
# extra script needed (see the note at the top of this script).
SHUTDOWN_CMD="/sbin/shutdown -h +0 UPS battery critical"
NOTIFY_LINES="NOTIFYCMD /usr/sbin/upssched"
if [[ $INSTALL_NOTIFY -eq 1 ]]; then
  NOTIFY_LINES="NOTIFYCMD ${NUT_ETC}/notify.sh
NOTIFYFLAG ONLINE    SYSLOG+EXEC
NOTIFYFLAG ONBATT    SYSLOG+EXEC
NOTIFYFLAG LOWBATT   SYSLOG+EXEC
NOTIFYFLAG FSD       SYSLOG+EXEC
NOTIFYFLAG COMMOK    SYSLOG+EXEC
NOTIFYFLAG COMMBAD   SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN  SYSLOG+EXEC
NOTIFYFLAG REPLBATT  SYSLOG+EXEC
NOTIFYFLAG NOCOMM    SYSLOG+EXEC
NOTIFYFLAG NOPARENT  SYSLOG+EXEC"
fi
cat > "${NUT_ETC}/upsmon.conf" <<EOF
# Managed by install-nut-eaton.sh
MONITOR ${UPS_NAME}@localhost 1 ${ADMIN_USER} ${ADMIN_PASSWORD} primary

MINSUPPLIES 1
SHUTDOWNCMD "${SHUTDOWN_CMD}"
${NOTIFY_LINES}
POLLFREQ 15
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
EOF

# ---------------------------------------------------------------------------
# 13. Fix ownership/permissions (NUT is picky about this)
# ---------------------------------------------------------------------------
log "Setting ownership and permissions on ${NUT_ETC}..."
chown root:nut "${NUT_ETC}"/nut.conf "${NUT_ETC}"/ups.conf "${NUT_ETC}"/upsd.conf \
  "${NUT_ETC}"/upsd.users "${NUT_ETC}"/upsmon.conf
chmod 640 "${NUT_ETC}"/ups.conf "${NUT_ETC}"/upsd.conf "${NUT_ETC}"/upsd.users "${NUT_ETC}"/upsmon.conf
chmod 644 "${NUT_ETC}"/nut.conf
if [[ $INSTALL_NOTIFY -eq 1 ]]; then
  chown root:root "${NUT_ETC}/notify.sh"
  chmod 755 "${NUT_ETC}/notify.sh"
fi

# ---------------------------------------------------------------------------
# 14. Enable and start services
# ---------------------------------------------------------------------------
log "Enabling and starting NUT services..."
systemctl daemon-reload

if systemctl list-unit-files nut-driver-enumerator.service >/dev/null 2>&1; then
  systemctl enable --now nut-driver-enumerator.service >/dev/null 2>&1 || true
  systemctl restart nut-driver-enumerator.service
  sleep 2
else
  upsdrvctl start || warn "upsdrvctl start reported an error - check 'upsdrvctl start ${UPS_NAME}' manually."
fi

systemctl enable --now nut-server.service
systemctl enable --now nut-monitor.service

sleep 2
systemctl restart nut-server.service
systemctl restart nut-monitor.service

# The driver runs as its own systemd unit (nut-driver@<name>.service),
# separate from nut-server/nut-monitor - restarting those two does not
# start or restart it. Make sure it's actually up before moving on.
if systemctl list-unit-files "nut-driver@${UPS_NAME}.service" >/dev/null 2>&1; then
  if ! systemctl is-active --quiet "nut-driver@${UPS_NAME}.service"; then
    log "Starting nut-driver@${UPS_NAME}.service..."
    systemctl restart "nut-driver@${UPS_NAME}.service" || \
      warn "nut-driver@${UPS_NAME}.service failed to start - check: journalctl -u nut-driver@${UPS_NAME} -n 30 (a USB permissions error there usually means the udev retrigger in step 3 didn't take on an already-plugged-in device; try re-plugging the UPS or rebooting)."
  fi
fi

# ---------------------------------------------------------------------------
# 15. Verify
# ---------------------------------------------------------------------------
log "Checking driver/server status..."
sleep 2
# mktemp, not a fixed /tmp/...$$ path: this runs as root and a predictable
# world-writable-directory filename is a classic symlink-attack target.
upsc_check_file="$(mktemp)"
if command -v upsc >/dev/null 2>&1 && upsc "${UPS_NAME}@localhost" >"$upsc_check_file" 2>&1; then
  log "UPS is reporting data:"
  sed -n '1,8p' "$upsc_check_file" | sed 's/^/[nut-setup]   /'
else
  warn "Could not query '${UPS_NAME}@localhost' yet. This is expected if the UPS isn't plugged in."
  warn "Once it is connected: systemctl status nut-driver@${UPS_NAME} ; upsc ${UPS_NAME}@localhost"
  warn "A USB permissions error in 'journalctl -u nut-driver@${UPS_NAME} -n 50' usually means"
  warn "the udev rule hasn't applied to this device yet - try re-plugging the UPS, or reboot."
fi
rm -f "$upsc_check_file"

log "Done."
echo
echo "=========================================================================="
echo "  CREDENTIALS - save these now. Generated passwords are only ever shown"
echo "  here; they're also in ${NUT_ETC}/upsd.users (root:nut, mode 640) if you"
echo "  need them again, but nothing prints them a second time."
echo "=========================================================================="
echo "  UPS name:          ${UPS_NAME}"
echo "  upsd admin user:   ${ADMIN_USER}"
if [[ $GENERATED_ADMIN_PASSWORD -eq 1 ]]; then
  echo "  upsd admin pass:   ${ADMIN_PASSWORD}"
else
  echo "  upsd admin pass:   (set via --admin-password, not repeated here)"
fi
if [[ $HA_USER_ENABLED -eq 1 ]]; then
  echo "  HA read-only user: ${HA_USER_NAME}"
  if [[ $GENERATED_HA_PASSWORD -eq 1 ]]; then
    echo "  HA read-only pass: ${HA_PASSWORD}"
  else
    echo "  HA read-only pass: (set via --ha-password, not repeated here)"
  fi
fi
echo "=========================================================================="
echo
echo "  Listening on:     127.0.0.1:3493$( [[ $LISTEN_LAN -eq 1 ]] && echo ', 0.0.0.0:3493 (LAN)' )"
echo "  On critical battery: host shuts down (Proxmox's pve-guests.service stops"
echo "                       all running guests first, automatically)."
if [[ $INSTALL_NOTIFY -eq 1 ]]; then
  echo "  Alerting:         emails ${NOTIFY_EMAIL} on UPS events (see ${NUT_ETC}/notify.sh)"
fi
echo
echo "Test the install with: upsc ${UPS_NAME}@localhost"
if [[ $INSTALL_NOTIFY -eq 1 ]]; then
  echo
  echo "Before trusting alerting: confirm root's local mail actually goes somewhere -"
  echo "  echo test | mail -s test ${NOTIFY_EMAIL}"
  echo "Test the alert path itself (safe - does not touch shutdown logic):"
  echo "  NOTIFYTYPE=ONBATT ${NUT_ETC}/notify.sh 'test message'"
  echo "Never use 'upsmon -c fsd' to test - on this primary instance it sets the real"
  echo "forced-shutdown flag and, combined with SHUTDOWNCMD, actually shuts the host down."
fi
if [[ $HA_USER_ENABLED -eq 1 ]]; then
  echo
  echo "In Home Assistant, add the NUT integration pointing at this node's IP,"
  echo "port 3493, UPS name '${UPS_NAME}', user '${HA_USER_NAME}'."
  echo "upsd is now reachable from the whole LAN (LISTEN 0.0.0.0/::) - consider"
  echo "restricting port 3493 to the Home Assistant VM's IP in your firewall"
  echo "(e.g. the Proxmox/Datacenter firewall), since NUT itself no longer"
  echo "does per-host access control."
fi
