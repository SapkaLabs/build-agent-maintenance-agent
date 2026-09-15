#!/bin/bash

set -u

PROGRAM_NAME="BuildAgentMaintenance"
LABEL="com.sapkalabs.build-agent-maintenance"
WATCHDOG_LABEL="com.sapkalabs.build-agent-maintenance-watchdog"
INSTALL_DIR="${HOME}/Library/Application Support/${PROGRAM_NAME}"
SHELL_PROFILE="${HOME}/.zshrc"
PROFILE_MARKER_BEGIN='# BuildAgentMaintenance command: begin'
PROFILE_MARKER_END='# BuildAgentMaintenance command: end'
PLIST_DIR="${HOME}/Library/LaunchAgents"
MAIN_PLIST="${PLIST_DIR}/${LABEL}.plist"
WATCHDOG_PLIST="${PLIST_DIR}/${WATCHDOG_LABEL}.plist"
DOMAIN="gui/$(/usr/bin/id -u)"

if [ -x "${INSTALL_DIR}/build-agent-maintenance.sh" ]; then
    "${INSTALL_DIR}/build-agent-maintenance.sh" --recover || true
fi

/bin/launchctl bootout "$DOMAIN" "$MAIN_PLIST" >/dev/null 2>&1 || true
/bin/launchctl bootout "$DOMAIN" "$WATCHDOG_PLIST" >/dev/null 2>&1 || true
/bin/rm -f "$MAIN_PLIST" "$WATCHDOG_PLIST"

if [ -f "$SHELL_PROFILE" ] && /usr/bin/grep -Fqx "$PROFILE_MARKER_BEGIN" "$SHELL_PROFILE"; then
    /usr/bin/sed -i '' "/^${PROFILE_MARKER_BEGIN}$/,/^${PROFILE_MARKER_END}$/d" "$SHELL_PROFILE"
fi

case "$INSTALL_DIR" in
    "${HOME}/Library/Application Support/${PROGRAM_NAME}") /bin/rm -rf -- "$INSTALL_DIR" ;;
    *) /usr/bin/printf 'Refusing unexpected install directory: %s\n' "$INSTALL_DIR" >&2; exit 1 ;;
esac

/usr/bin/printf 'Uninstalled %s. Maintenance logs were preserved.\n' "$PROGRAM_NAME"
