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
#   --admin-password PASS Password for --admin-user (skips the interactive prompt)
#   --ha-user              Create a second, read-only upsd account for Home
#                          Assistant's NUT integration (name: homeassistant)
#   --ha-user-name NAME    Override the Home Assistant account name
#   --ha-password PASS     Password for the Home Assistant account (skips prompt)
#   --generate-password   Generate random passwords instead of prompting
#   --listen-lan          Also listen on all interfaces (default: localhost only;
#                          implied by --ha-user, since a VM isn't on loopback)
#   --no-guest-shutdown   Do not install the VM/LXC graceful-shutdown helper
#   --uninstall           Remove the NUT config this script created and stop services
#   -y, --yes             Do not prompt for confirmation
#   -h, --help            Show this help text
#
# Re-running this script is safe: existing config files are backed up with a
# .bak-<timestamp> suffix before being rewritten.
#
# Note on "read-only": NUT's protocol does not gate status reads (GET VAR /
# LIST VAR - what upsc and the Home Assistant integration use) behind
# authentication at all; any client that can reach upsd's LISTEN address can
# read UPS status regardless of credentials. The --ha-user account can't
# authenticate as a monitor master or run control commands (SET/INSTCMD), so
# it can't shut anything down or change UPS settings - but the real fence
# around *who can read* is the LISTEN bind address plus your firewall, not
# this password. See the README for a firewall recommendation.

set -euo pipefail

UPS_NAME="eaton3s"
ADMIN_USER="upsmon"
ADMIN_PASSWORD=""
HA_USER_ENABLED=0
HA_USER_NAME="homeassistant"
HA_PASSWORD=""
GENERATE_PASSWORD=0
LISTEN_LAN=0
INSTALL_GUEST_SHUTDOWN=1
ASSUME_YES=0
UNINSTALL=0

# When run from a cloned checkout, BASH_SOURCE[0] points at this file and we
# copy the helper from next to it. When run via `curl | bash` there is no
# local checkout (BASH_SOURCE[0] is unset and $0 is just "bash"), so the
# helper is downloaded from this same repo instead - see step 4 below.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
SHUTDOWN_HELPER_SRC="${SCRIPT_DIR}/scripts/pve-guest-shutdown.sh"
SHUTDOWN_HELPER_DST="/usr/local/bin/pve-guest-shutdown.sh"
REPO_RAW_BASE="https://raw.githubusercontent.com/ChaoticOrb/Proxmox-UPS-Eaton/main"
NUT_ETC="/etc/nut"
EATON_USB_VENDOR="0463"

log()  { echo "[nut-setup] $*"; }
warn() { echo "[nut-setup] WARNING: $*" >&2; }
die()  { echo "[nut-setup] ERROR: $*" >&2; exit 1; }

usage() { sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ups-name) UPS_NAME="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --ha-user) HA_USER_ENABLED=1; shift ;;
    --ha-user-name) HA_USER_ENABLED=1; HA_USER_NAME="$2"; shift 2 ;;
    --ha-password) HA_USER_ENABLED=1; HA_PASSWORD="$2"; shift 2 ;;
    --generate-password) GENERATE_PASSWORD=1; shift ;;
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

prompt_password() {
  # $1 = variable name to assign into, $2 = human-readable label for the prompt
  local outvar="$1" label="$2" pass1 pass2
  while true; do
    read -r -s -p "Enter password for ${label}: " pass1; echo
    read -r -s -p "Confirm password: " pass2; echo
    if [[ -z "$pass1" ]]; then
      echo "Password cannot be empty." >&2
      continue
    fi
    if [[ "$pass1" != "$pass2" ]]; then
      echo "Passwords did not match, try again." >&2
      continue
    fi
    printf -v "$outvar" '%s' "$pass1"
    break
  done
}

# Resolves a password into $1 from (in order): an explicit value already
# supplied, an interactive prompt, or a random string. Sets
# LAST_PASSWORD_GENERATED=1 when it had to generate one (no explicit value
# and either --generate-password was passed or there's no terminal).
resolve_password() {
  local outvar="$1" explicit="$2" label="$3"
  LAST_PASSWORD_GENERATED=0
  if [[ -n "$explicit" ]]; then
    printf -v "$outvar" '%s' "$explicit"
  elif [[ $GENERATE_PASSWORD -eq 1 ]]; then
    printf -v "$outvar" '%s' "$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    LAST_PASSWORD_GENERATED=1
  elif [[ -t 0 ]]; then
    prompt_password "$outvar" "$label"
  else
    warn "No password given for ${label} and no terminal to prompt on; generating a random password."
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
# 3. Install the guest graceful-shutdown helper (or fetch it, if we're
#    running via `curl | bash` with no local checkout to copy it from).
#    Done before upsmon.conf is written, since that file's SHUTDOWNCMD
#    depends on whether this succeeded.
# ---------------------------------------------------------------------------
if [[ $INSTALL_GUEST_SHUTDOWN -eq 1 ]]; then
  if [[ -f "$SHUTDOWN_HELPER_SRC" ]]; then
    log "Installing guest shutdown helper to ${SHUTDOWN_HELPER_DST}..."
    install -m 0755 -o root -g root "$SHUTDOWN_HELPER_SRC" "$SHUTDOWN_HELPER_DST"
  else
    log "No local checkout found - fetching guest shutdown helper from ${REPO_RAW_BASE}..."
    tmp_helper="$(mktemp)"
    if command -v curl >/dev/null 2>&1 && curl -fsSL "${REPO_RAW_BASE}/scripts/pve-guest-shutdown.sh" -o "$tmp_helper"; then
      install -m 0755 -o root -g root "$tmp_helper" "$SHUTDOWN_HELPER_DST"
      rm -f "$tmp_helper"
    else
      rm -f "$tmp_helper"
      warn "Could not download the guest shutdown helper; continuing without it."
      warn "upsmon will shut down the host directly without stopping VMs/LXCs first."
      warn "Re-run with --no-guest-shutdown to silence this warning."
      INSTALL_GUEST_SHUTDOWN=0
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Determine passwords: explicit flag > interactive prompt > random
#    generation (only when --generate-password was requested, or there's no
#    terminal to prompt on). If a read-only Home Assistant account was
#    requested, it needs the server reachable off-loopback (HA runs in its
#    own VM), so imply --listen-lan unless the user already set it.
# ---------------------------------------------------------------------------
resolve_password ADMIN_PASSWORD "$ADMIN_PASSWORD" "upsd user '${ADMIN_USER}'"
GENERATED_ADMIN_PASSWORD=$LAST_PASSWORD_GENERATED

if [[ $HA_USER_ENABLED -eq 1 ]]; then
  resolve_password HA_PASSWORD "$HA_PASSWORD" "Home Assistant read-only user '${HA_USER_NAME}'"
  GENERATED_HA_PASSWORD=$LAST_PASSWORD_GENERATED

  if [[ $LISTEN_LAN -eq 0 ]]; then
    log "Home Assistant account requested - enabling --listen-lan so upsd is reachable from the HA VM."
    LISTEN_LAN=1
  fi
fi

# ---------------------------------------------------------------------------
# 5. nut.conf - standalone mode (this node runs driver + server + monitor)
# ---------------------------------------------------------------------------
log "Writing ${NUT_ETC}/nut.conf..."
backup_file "${NUT_ETC}/nut.conf"
cat > "${NUT_ETC}/nut.conf" <<EOF
MODE=standalone
EOF

# ---------------------------------------------------------------------------
# 6. ups.conf - the Eaton 3S is USB HID compliant; usbhid-ups auto-detects it
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
# 7. upsd.conf - who can connect to the data server
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
# 8. upsd.users - credentials for clients connecting to upsd
# ---------------------------------------------------------------------------
HA_USER_LOG_SUFFIX=""
[[ $HA_USER_ENABLED -eq 1 ]] && HA_USER_LOG_SUFFIX=", ${HA_USER_NAME}"
log "Writing ${NUT_ETC}/upsd.users (user: ${ADMIN_USER}${HA_USER_LOG_SUFFIX})..."
backup_file "${NUT_ETC}/upsd.users"
cat > "${NUT_ETC}/upsd.users" <<EOF
# Managed by install-nut-eaton.sh
[${ADMIN_USER}]
    password = ${ADMIN_PASSWORD}
    upsmon master
EOF

if [[ $HA_USER_ENABLED -eq 1 ]]; then
  cat >> "${NUT_ETC}/upsd.users" <<EOF

# Read-only account for Home Assistant's NUT integration: no 'upsmon'
# directive and no actions/instcmds, so it cannot become monitor master or
# run control commands. See the note at the top of this script re: NUT not
# gating status reads (GET VAR/LIST VAR) behind auth at all.
[${HA_USER_NAME}]
    password = ${HA_PASSWORD}
EOF
fi

# ---------------------------------------------------------------------------
# 9. upsmon.conf - local monitoring + shutdown trigger
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
# 10. Fix ownership/permissions (NUT is picky about this)
# ---------------------------------------------------------------------------
log "Setting ownership and permissions on ${NUT_ETC}..."
chown root:nut "${NUT_ETC}"/nut.conf "${NUT_ETC}"/ups.conf "${NUT_ETC}"/upsd.conf \
  "${NUT_ETC}"/upsd.users "${NUT_ETC}"/upsmon.conf
chmod 640 "${NUT_ETC}"/ups.conf "${NUT_ETC}"/upsd.conf "${NUT_ETC}"/upsd.users "${NUT_ETC}"/upsmon.conf
chmod 644 "${NUT_ETC}"/nut.conf

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
echo "  UPS name:         ${UPS_NAME}"
echo "  upsd admin user:  ${ADMIN_USER}"
if [[ $GENERATED_ADMIN_PASSWORD -eq 1 ]]; then
  echo "  upsd admin pass:  ${ADMIN_PASSWORD}   (generated - stored in ${NUT_ETC}/upsd.users)"
fi
if [[ $HA_USER_ENABLED -eq 1 ]]; then
  echo "  HA read-only user: ${HA_USER_NAME}"
  if [[ $GENERATED_HA_PASSWORD -eq 1 ]]; then
    echo "  HA read-only pass: ${HA_PASSWORD}   (generated - stored in ${NUT_ETC}/upsd.users)"
  fi
fi
echo "  Listening on:     127.0.0.1:3493$( [[ $LISTEN_LAN -eq 1 ]] && echo ', 0.0.0.0:3493 (LAN)' )"
if [[ $INSTALL_GUEST_SHUTDOWN -eq 1 ]]; then
  echo "  On critical battery: VMs/LXCs are shut down gracefully, then the host powers off"
  echo "                       (see ${SHUTDOWN_HELPER_DST})."
fi
echo
echo "Test the install with: upsc ${UPS_NAME}@localhost"
if [[ $HA_USER_ENABLED -eq 1 ]]; then
  echo
  echo "In Home Assistant, add the NUT integration pointing at this node's IP,"
  echo "port 3493, UPS name '${UPS_NAME}', user '${HA_USER_NAME}'."
  echo "upsd is now reachable from the whole LAN (LISTEN 0.0.0.0/::) - consider"
  echo "restricting port 3493 to the Home Assistant VM's IP in your firewall"
  echo "(e.g. the Proxmox/Datacenter firewall), since NUT itself no longer"
  echo "does per-host access control."
fi
