#!/usr/bin/env bash
#
# install-nut-eaton.sh
#
# Installs and configures Network UPS Tools (NUT) on a Proxmox VE node for a
# USB-connected Eaton 3S UPS, in standalone mode. Also installs a shutdown
# helper that gracefully stops running VMs/LXCs before the host powers off
# on a critical battery event.
#
# Usage:
#   ./install-nut-eaton.sh [options]
#
# Options:
#   --ups-name NAME       Name used for the UPS in ups.conf (default: eaton3s)
#   --admin-user USER     upsd admin/monitoring username (default: upsmon)
#   --admin-password PASS Password for --admin-user (default: randomly generated)
#   --listen-lan          Also listen on all interfaces (default: localhost only)
#   --no-guest-shutdown   Do not install the VM/LXC graceful-shutdown helper
#   --uninstall           Remove the NUT config this script created and stop services
#   -y, --yes             Do not prompt for confirmation
#   -h, --help            Show this help text
#
# Re-running this script is safe: existing config files are backed up with a
# .bak-<timestamp> suffix before being rewritten.

set -euo pipefail

UPS_NAME="eaton3s"
ADMIN_USER="upsmon"
ADMIN_PASSWORD=""
LISTEN_LAN=0
INSTALL_GUEST_SHUTDOWN=1
ASSUME_YES=0
UNINSTALL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHUTDOWN_HELPER_SRC="${SCRIPT_DIR}/scripts/pve-guest-shutdown.sh"
SHUTDOWN_HELPER_DST="/usr/local/bin/pve-guest-shutdown.sh"
NUT_ETC="/etc/nut"
EATON_USB_VENDOR="0463"

log()  { echo "[nut-setup] $*"; }
warn() { echo "[nut-setup] WARNING: $*" >&2; }
die()  { echo "[nut-setup] ERROR: $*" >&2; exit 1; }

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ups-name) UPS_NAME="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --listen-lan) LISTEN_LAN=1; shift ;;
    --no-guest-shutdown) INSTALL_GUEST_SHUTDOWN=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Must be run as root (use sudo)."
command -v apt-get >/dev/null 2>&1 || die "This script targets Debian/Proxmox (apt-get not found)."

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -p "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)"
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local prompt="$1"
  read -r -p "${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
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
  rm -f "$SHUTDOWN_HELPER_DST"
  log "NUT configuration left in place under ${NUT_ETC} (remove manually or 'apt purge nut' if desired)."
  log "Uninstall steps complete."
  exit 0
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
# 3. Generate an admin password if one wasn't supplied
# ---------------------------------------------------------------------------
if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  GENERATED_PASSWORD=1
else
  GENERATED_PASSWORD=0
fi

# ---------------------------------------------------------------------------
# 4. nut.conf - standalone mode (this node runs driver + server + monitor)
# ---------------------------------------------------------------------------
log "Writing ${NUT_ETC}/nut.conf..."
backup_file "${NUT_ETC}/nut.conf"
cat > "${NUT_ETC}/nut.conf" <<EOF
MODE=standalone
EOF

# ---------------------------------------------------------------------------
# 5. ups.conf - the Eaton 3S is USB HID compliant; usbhid-ups auto-detects it
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
# 6. upsd.conf - who can connect to the data server
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
# 7. upsd.users - credentials upsmon uses to log in to upsd
# ---------------------------------------------------------------------------
log "Writing ${NUT_ETC}/upsd.users (user: ${ADMIN_USER})..."
backup_file "${NUT_ETC}/upsd.users"
cat > "${NUT_ETC}/upsd.users" <<EOF
# Managed by install-nut-eaton.sh
[${ADMIN_USER}]
    password = ${ADMIN_PASSWORD}
    upsmon master
EOF

# ---------------------------------------------------------------------------
# 8. upsmon.conf - local monitoring + shutdown trigger
# ---------------------------------------------------------------------------
log "Writing ${NUT_ETC}/upsmon.conf..."
backup_file "${NUT_ETC}/upsmon.conf"
SHUTDOWN_CMD="/sbin/shutdown -h +0 \"UPS battery critical\""
if [[ $INSTALL_GUEST_SHUTDOWN -eq 1 ]]; then
  SHUTDOWN_CMD="${SHUTDOWN_HELPER_DST}"
fi
cat > "${NUT_ETC}/upsmon.conf" <<EOF
# Managed by install-nut-eaton.sh
MONITOR ${UPS_NAME}@localhost 1 ${ADMIN_USER} ${ADMIN_PASSWORD} master

MINSUPPLIES 1
SHUTDOWNCMD "${SHUTDOWN_CMD}"
NOTIFYCMD /usr/sbin/upssched
POLLFREQ 15
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
EOF

# ---------------------------------------------------------------------------
# 9. Fix ownership/permissions (NUT is picky about this)
# ---------------------------------------------------------------------------
log "Setting ownership and permissions on ${NUT_ETC}..."
chown root:nut "${NUT_ETC}"/nut.conf "${NUT_ETC}"/ups.conf "${NUT_ETC}"/upsd.conf \
  "${NUT_ETC}"/upsd.users "${NUT_ETC}"/upsmon.conf
chmod 640 "${NUT_ETC}"/ups.conf "${NUT_ETC}"/upsd.conf "${NUT_ETC}"/upsd.users "${NUT_ETC}"/upsmon.conf
chmod 644 "${NUT_ETC}"/nut.conf

# ---------------------------------------------------------------------------
# 10. Install the guest graceful-shutdown helper
# ---------------------------------------------------------------------------
if [[ $INSTALL_GUEST_SHUTDOWN -eq 1 ]]; then
  [[ -f "$SHUTDOWN_HELPER_SRC" ]] || die "Missing ${SHUTDOWN_HELPER_SRC} - re-clone the repo."
  log "Installing guest shutdown helper to ${SHUTDOWN_HELPER_DST}..."
  install -m 0755 -o root -g root "$SHUTDOWN_HELPER_SRC" "$SHUTDOWN_HELPER_DST"
fi

# ---------------------------------------------------------------------------
# 11. Enable and start services
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

# ---------------------------------------------------------------------------
# 12. Verify
# ---------------------------------------------------------------------------
log "Checking driver/server status..."
sleep 2
if command -v upsc >/dev/null 2>&1 && upsc "${UPS_NAME}@localhost" >/tmp/upsc-check.$$ 2>&1; then
  log "UPS is reporting data:"
  sed -n '1,8p' /tmp/upsc-check.$$ | sed 's/^/[nut-setup]   /'
  rm -f /tmp/upsc-check.$$
else
  warn "Could not query '${UPS_NAME}@localhost' yet. This is expected if the UPS isn't plugged in."
  warn "Once it is connected, check with: upsc ${UPS_NAME}@localhost"
  warn "and driver logs with: journalctl -u nut-server -u 'nut-driver@${UPS_NAME}' -n 50"
  rm -f /tmp/upsc-check.$$
fi

log "Done."
echo
echo "  UPS name:        ${UPS_NAME}"
echo "  upsd admin user:  ${ADMIN_USER}"
if [[ $GENERATED_PASSWORD -eq 1 ]]; then
  echo "  upsd admin pass:  ${ADMIN_PASSWORD}   (generated - stored in ${NUT_ETC}/upsd.users)"
fi
echo "  Listening on:     127.0.0.1:3493$( [[ $LISTEN_LAN -eq 1 ]] && echo ', 0.0.0.0:3493 (LAN)' )"
if [[ $INSTALL_GUEST_SHUTDOWN -eq 1 ]]; then
  echo "  On critical battery: VMs/LXCs are shut down gracefully, then the host powers off"
  echo "                       (see ${SHUTDOWN_HELPER_DST})."
fi
echo
echo "Test the install with: upsc ${UPS_NAME}@localhost"
