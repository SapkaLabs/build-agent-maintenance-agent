#!/bin/bash

WATCHDOG_STALE_SECONDS=60
WATCHDOG_HARD_TIMEOUT_SECONDS=3600

set -u

PROGRAM_NAME="BuildAgentMaintenance"
INSTALL_DIR="${BAMA_INSTALL_DIR:-${HOME}/Library/Application Support/${PROGRAM_NAME}}"
STATE_DIR="${BAMA_STATE_DIR:-${INSTALL_DIR}/state}"
RECOVERY_DIR="${STATE_DIR}/recovery"
LOG_DIR="${BAMA_LOG_DIR:-${HOME}/Documents/${PROGRAM_NAME}}"
MAINTENANCE_SCRIPT="${INSTALL_DIR}/build-agent-maintenance.sh"

now=$(/bin/date '+%s')
[ -d "$RECOVERY_DIR" ] || exit 0

started=$(/usr/bin/sed -n '1p' "${RECOVERY_DIR}/started-epoch" 2>/dev/null || /usr/bin/printf '0')
modified=$(/usr/bin/stat -f '%m' "${RECOVERY_DIR}/heartbeat" 2>/dev/null || /usr/bin/printf '0')
case "$started" in *[!0-9]*|'') started=0 ;; esac
case "$modified" in *[!0-9]*|'') modified=0 ;; esac

if [ $((now - started)) -lt "$WATCHDOG_HARD_TIMEOUT_SECONDS" ] && [ $((now - modified)) -lt "$WATCHDOG_STALE_SECONDS" ]; then
    exit 0
fi

/bin/mkdir -p "$LOG_DIR"
log_file="${LOG_DIR}/recovery-$(/bin/date '+%Y%m%d-%H%M%S').log"
/usr/bin/printf '%s [WARN] Watchdog found an abandoned maintenance marker.\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S%z')" >> "$log_file"

if [ ! -x "$MAINTENANCE_SCRIPT" ]; then
    /usr/bin/printf '%s [ERROR] Maintenance script is missing or not executable: %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S%z')" "$MAINTENANCE_SCRIPT" >> "$log_file"
    exit 1
fi

"$MAINTENANCE_SCRIPT" --recover >> "$log_file" 2>&1
