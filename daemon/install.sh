#!/usr/bin/env bash
# install.sh — install, uninstall, or check status of the lunation ambient daemon.
#
#   sudo ./install.sh           # install (default)
#   sudo ./install.sh uninstall
#   ./install.sh status

set -euo pipefail

DAEMON_LABEL="dev.lunation.daemon"
PLIST_DST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
INSTALL_DIR="/usr/local/lib/lunation"
CONFIG_DIR="/etc/lunation"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
require_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "error: must run as root — use: sudo $0 $*" >&2; exit 1; }
}

daemon_loaded() {
  launchctl list 2>/dev/null | grep -q "$DAEMON_LABEL"
}

# Load/unload via the modern launchctl domain API (bootstrap/bootout), falling
# back to the legacy load/unload on older macOS so installs never silently fail.
load_daemon() {
  launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true   # ensure clean slate
  launchctl enable "system/$DAEMON_LABEL" 2>/dev/null || true    # clear any disabled override
  launchctl bootstrap system "$PLIST_DST" 2>/dev/null \
    || launchctl load -w "$PLIST_DST"
}
unload_daemon() {
  launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null \
    || launchctl unload "$PLIST_DST" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
cmd="${1:-install}"

case "$cmd" in

install)
  require_root install

  # Check for python3
  if ! /usr/bin/python3 --version &>/dev/null; then
    echo "error: /usr/bin/python3 not found. Install Xcode Command Line Tools:" >&2
    echo "       xcode-select --install" >&2
    exit 1
  fi

  echo "Installing lunation daemon..."

  install -d "$INSTALL_DIR" "$CONFIG_DIR"
  install -m 755 "$SCRIPT_DIR/lunation-daemon" "$INSTALL_DIR/lunation-daemon"

  # Make the config dir writable by the installing user so the menu-bar app
  # (running as that user) can write config.json and intent.json without sudo.
  REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
  chown -R "$REAL_USER" "$CONFIG_DIR"

  # Create default config only if one doesn't already exist
  if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
    cat > "$CONFIG_DIR/config.json" << 'EOF'
{
  "grace_period_seconds": 90,
  "poll_interval_seconds": 10,
  "allow_battery": false,
  "thermal_cutoff": 50,
  "heartbeat_window_seconds": 180,
  "sleep_when_lid_closed": true,
  "lid_input_quiet_seconds": 300
}
EOF
    echo "  Created default config: $CONFIG_DIR/config.json"
  else
    echo "  Existing config preserved: $CONFIG_DIR/config.json"
  fi

  # Install plist
  install -m 644 -o root -g wheel \
    "$SCRIPT_DIR/dev.lunation.daemon.plist" "$PLIST_DST"

  # Clean up a previous com.lunation.daemon install (label renamed to dev.lunation.daemon).
  OLD_PLIST=/Library/LaunchDaemons/com.lunation.daemon.plist
  if [[ -f "$OLD_PLIST" ]] || launchctl list 2>/dev/null | grep -q "com.lunation.daemon"; then
    launchctl bootout "system/com.lunation.daemon" 2>/dev/null \
      || launchctl unload "$OLD_PLIST" 2>/dev/null || true
    rm -f "$OLD_PLIST"
    echo "  Removed previous com.lunation.daemon"
  fi

  # Unload first if already running (upgrade path)
  if daemon_loaded; then
    echo "  Stopping existing daemon..."
    unload_daemon
  fi

  load_daemon
  echo ""
  echo "Daemon installed and running."
  echo "  Log:    /var/log/lunation-daemon.log"
  echo "  Config: $CONFIG_DIR/config.json"
  echo ""
  echo "To watch the log live:  tail -f /var/log/lunation-daemon.log"
  echo "To check sleep state:   pmset -g | grep SleepDisabled"
  ;;

uninstall)
  require_root uninstall

  echo "Uninstalling lunation daemon..."

  # Safety: always re-enable sleep before removing the daemon
  /usr/bin/pmset -a disablesleep 0 2>/dev/null && echo "  disablesleep reset to 0" || true

  if daemon_loaded; then
    unload_daemon
  fi
  [[ -f "$PLIST_DST" ]] && rm "$PLIST_DST"

  rm -rf "$INSTALL_DIR"

  echo "Daemon uninstalled."
  echo "(Config preserved at $CONFIG_DIR — remove manually if desired: sudo rm -rf $CONFIG_DIR)"
  ;;

status)
  if daemon_loaded; then
    echo "Daemon: running  ($DAEMON_LABEL)"
  else
    echo "Daemon: NOT running"
  fi
  echo -n "Sleep state: "
  pmset -g | grep SleepDisabled || echo "(SleepDisabled key not found)"
  echo -n "Power source: "
  pmset -g ps | grep -E "AC Power|Battery Power" || echo "unknown"
  if [[ -f /var/log/lunation-daemon.log ]]; then
    echo ""
    echo "--- last 10 log lines ---"
    tail -10 /var/log/lunation-daemon.log
  fi
  ;;

*)
  echo "usage: $0 [install|uninstall|status]" >&2
  exit 1
  ;;

esac
