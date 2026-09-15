#!/bin/bash

set -u

PROGRAM_NAME="BuildAgentMaintenance"
LABEL="com.sapkalabs.build-agent-maintenance"
WATCHDOG_LABEL="com.sapkalabs.build-agent-maintenance-watchdog"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
INSTALL_DIR="${HOME}/Library/Application Support/${PROGRAM_NAME}"
PLIST_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs/${PROGRAM_NAME}"
MAIN_PLIST="${PLIST_DIR}/${LABEL}.plist"
WATCHDOG_PLIST="${PLIST_DIR}/${WATCHDOG_LABEL}.plist"
DOMAIN="gui/$(/usr/bin/id -u)"

if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    /usr/bin/printf '%s\n' 'Do not run this installer with sudo. Run it as the Azure agent user.' >&2
    exit 1
fi

xml_escape() {
    /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

escaped_install=$(/usr/bin/printf '%s' "$INSTALL_DIR" | xml_escape)
escaped_log=$(/usr/bin/printf '%s' "$LOG_DIR" | xml_escape)

/bin/mkdir -p "$INSTALL_DIR" "$PLIST_DIR" "$LOG_DIR"
/usr/bin/install -m 700 "${SCRIPT_DIR}/build-agent-maintenance.sh" "${INSTALL_DIR}/build-agent-maintenance.sh"
/usr/bin/install -m 700 "${SCRIPT_DIR}/build-agent-watchdog.sh" "${INSTALL_DIR}/build-agent-watchdog.sh"

/bin/cat > "$MAIN_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${escaped_install}/build-agent-maintenance.sh</string>
    <string>--daemon</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${escaped_log}/scheduler.stdout.log</string>
  <key>StandardErrorPath</key><string>${escaped_log}/scheduler.stderr.log</string>
</dict>
</plist>
EOF

/bin/cat > "$WATCHDOG_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${WATCHDOG_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${escaped_install}/build-agent-watchdog.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>15</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${escaped_log}/watchdog.stdout.log</string>
  <key>StandardErrorPath</key><string>${escaped_log}/watchdog.stderr.log</string>
</dict>
</plist>
EOF

/usr/bin/plutil -lint "$MAIN_PLIST" "$WATCHDOG_PLIST"
/bin/launchctl bootout "$DOMAIN" "$MAIN_PLIST" >/dev/null 2>&1 || true
/bin/launchctl bootout "$DOMAIN" "$WATCHDOG_PLIST" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "$DOMAIN" "$WATCHDOG_PLIST"
/bin/launchctl bootstrap "$DOMAIN" "$MAIN_PLIST"
/bin/launchctl enable "${DOMAIN}/${WATCHDOG_LABEL}"
/bin/launchctl enable "${DOMAIN}/${LABEL}"

/usr/bin/printf 'Installed %s in %s\n' "$LABEL" "$INSTALL_DIR"
/usr/bin/printf 'Schedule: 2100, 2400, 0230 local time. Installation does not run maintenance immediately.\n'
