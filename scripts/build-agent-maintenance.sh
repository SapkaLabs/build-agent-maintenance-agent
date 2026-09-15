#!/bin/bash

# User-configurable constants. Times use the Mac's local HHMM time. 2400 means midnight.
MAINTENANCE_TIMES=("2100" "2400" "0230")
MINIMUM_FREE_DISK_PERCENT=20
BUILD_DRAIN_SECONDS=30
SIMULATOR_SHUTDOWN_WAIT_SECONDS=30
PROCESS_TERM_WAIT_SECONDS=10
WORK_DELETE_RETRIES=3
WORK_DELETE_RETRY_SECONDS=5
SCHEDULER_POLL_SECONDS=15
WATCHDOG_HARD_TIMEOUT_SECONDS=3600
AGENT_SEARCH_ROOTS=("${HOME}/azba")
XCODE_DERIVED_DATA_DIR="${HOME}/Library/Developer/Xcode/DerivedData"

set -o pipefail

PROGRAM_NAME="BuildAgentMaintenance"
INSTALL_DIR="${BAMA_INSTALL_DIR:-${HOME}/Library/Application Support/${PROGRAM_NAME}}"
STATE_DIR="${BAMA_STATE_DIR:-${INSTALL_DIR}/state}"
LOG_DIR="${BAMA_LOG_DIR:-${HOME}/Documents/${PROGRAM_NAME}}"
RECOVERY_DIR="${STATE_DIR}/recovery"
LOCK_DIR="${STATE_DIR}/maintenance.lock"
SCHEDULE_STATE_FILE="${STATE_DIR}/last-schedule-slot"
LOG_FILE=""
DRY_RUN=0
RECOVERY_ACTIVE=0
HEARTBEAT_PID=""
LOCK_ACQUIRED=0

if [ -n "${BAMA_AGENT_SEARCH_ROOTS:-}" ]; then
    OLD_IFS=$IFS
    IFS=':'
    AGENT_SEARCH_ROOTS=(${BAMA_AGENT_SEARCH_ROOTS})
    IFS=$OLD_IFS
fi

timestamp() {
    /bin/date '+%Y-%m-%d %H:%M:%S%z'
}

log() {
    local line
    line="$(timestamp) [$1] $2"
    /usr/bin/printf '%s\n' "$line"
    if [ -n "$LOG_FILE" ]; then
        /usr/bin/printf '%s\n' "$line" >> "$LOG_FILE"
    fi
}

notify_user() {
    local message=$1
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    /usr/bin/osascript -e "display notification \"${message}\" with title \"Build agent maintenance\"" >/dev/null 2>&1 || true
}

ensure_runtime_directories() {
    /bin/mkdir -p "$STATE_DIR" "$LOG_DIR"
    /bin/chmod 700 "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true
}

validate_dependencies() {
    local command missing
    missing=0
    for command in /bin/bash /bin/cat /bin/chmod /bin/date /bin/df /bin/kill /bin/launchctl /bin/mkdir /bin/mv /bin/ps /bin/rm /bin/rmdir /bin/sleep /usr/bin/awk /usr/bin/basename /usr/bin/dirname /usr/bin/find /usr/bin/install /usr/bin/osascript /usr/bin/printf /usr/bin/python3 /usr/bin/sed /usr/bin/sort /usr/bin/stat /usr/bin/touch /usr/bin/tr /usr/bin/wc /usr/bin/xcrun; do
        if [ ! -x "$command" ]; then
            log ERROR "Required executable is missing: $command"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

start_run_log() {
    ensure_runtime_directories
    LOG_FILE="${LOG_DIR}/maintenance-$(/bin/date '+%Y%m%d-%H%M%S').log"
    : > "$LOG_FILE"
    /bin/chmod 600 "$LOG_FILE" 2>/dev/null || true
}

normalize_schedule_time() {
    local value=$1
    case "$value" in
        2400) /usr/bin/printf '%s\n' '0000'; return 0 ;;
        [0-1][0-9][0-5][0-9]|2[0-3][0-5][0-9]) /usr/bin/printf '%s\n' "$value"; return 0 ;;
        *) return 1 ;;
    esac
}

validate_schedule() {
    local slot
    for slot in "${MAINTENANCE_TIMES[@]}"; do
        if ! normalize_schedule_time "$slot" >/dev/null; then
            log ERROR "Invalid MAINTENANCE_TIMES value: ${slot}. Expected HHMM or 2400."
            return 1
        fi
    done
    return 0
}

discover_agents() {
    local root marker agent canonical_root canonical_agent existing item
    DISCOVERED_AGENTS=()
    for root in "${AGENT_SEARCH_ROOTS[@]}"; do
        [ -d "$root" ] || continue
        canonical_root=$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root") || continue
        while IFS= read -r marker; do
            agent=${marker%/.agent}
            [ -x "${agent}/svc.sh" ] || continue
            [ -f "${agent}/.service" ] || continue
            canonical_agent=$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$agent") || continue
            case "$canonical_agent" in
                "${canonical_root}"/*) ;;
                *) log WARN "Ignoring agent outside its configured search root: ${agent}"; continue ;;
            esac
            existing=0
            for item in "${DISCOVERED_AGENTS[@]}"; do
                [ "$item" = "$canonical_agent" ] && existing=1
            done
            [ "$existing" -eq 0 ] && DISCOVERED_AGENTS+=("$canonical_agent")
        done < <(/usr/bin/find "$root" -mindepth 2 -maxdepth 2 -type f -name .agent -print 2>/dev/null | /usr/bin/sort)
    done
    [ "${#DISCOVERED_AGENTS[@]}" -gt 0 ]
}

agent_plist() {
    local agent=$1 plist
    plist=$(/usr/bin/sed -n '1p' "${agent}/.service" 2>/dev/null || true)
    case "$plist" in
        "${HOME}/Library/LaunchAgents/"*.plist) /usr/bin/printf '%s\n' "$plist" ;;
        *) return 1 ;;
    esac
}

agent_label() {
    local plist
    plist=$(agent_plist "$1") || return 1
    /usr/bin/basename "$plist" .plist
}

agent_is_running() {
    local label
    label=$(agent_label "$1") || return 1
    /bin/launchctl list 2>/dev/null | /usr/bin/awk -v wanted="$label" '$3 == wanted && $1 ~ /^[0-9]+$/ { found=1 } END { exit(found ? 0 : 1) }'
}

agent_job_is_loaded() {
    local label
    label=$(agent_label "$1") || return 1
    /bin/launchctl list "$label" >/dev/null 2>&1
}

command_is_agent_worker() {
    local agent=$1 command=$2
    case "$command" in
        "${agent}"/bin/Agent.Worker|"${agent}"/bin/Agent.Worker\ *) return 0 ;;
        "${agent}"/bin.*/Agent.Worker|"${agent}"/bin.*/Agent.Worker\ *) return 0 ;;
        *) return 1 ;;
    esac
}

agent_has_worker() {
    local agent=$1 line
    while IFS= read -r line; do
        command_is_agent_worker "$agent" "$line" && return 0
    done < <(/bin/ps -axo command= 2>/dev/null)
    return 1
}

stop_agent() {
    local agent=$1 plist output attempt
    if ! agent_is_running "$agent" && ! agent_job_is_loaded "$agent"; then
        log INFO "Agent already stopped: $agent"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log DRYRUN "Would stop agent: $agent"
        return 0
    fi
    log INFO "Stopping agent: $agent"
    output=$(cd "$agent" && ./svc.sh stop 2>&1) || log WARN "svc.sh stop reported an error for $agent: $output"
    if agent_is_running "$agent"; then
        plist=$(agent_plist "$agent") || return 1
        output=$(/bin/launchctl unload "$plist" 2>&1) || log WARN "launchctl unload reported an error for $agent: $output"
    fi
    attempt=0
    while agent_is_running "$agent" && [ "$attempt" -lt 5 ]; do
        /bin/sleep 1
        attempt=$((attempt + 1))
    done
    if agent_is_running "$agent"; then
        log ERROR "Agent service is still running after stop: $agent"
        return 1
    fi
    log INFO "Agent stopped: $agent"
    return 0
}

start_agent() {
    local agent=$1 plist output attempt
    if agent_is_running "$agent"; then
        log INFO "Agent already running: $agent"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log DRYRUN "Would start agent: $agent"
        return 0
    fi
    if agent_job_is_loaded "$agent"; then
        plist=$(agent_plist "$agent") || return 1
        /bin/launchctl unload "$plist" >/dev/null 2>&1 || true
    fi
    log INFO "Starting agent: $agent"
    output=$(cd "$agent" && ./svc.sh start 2>&1) || log WARN "svc.sh start reported an error for $agent: $output"
    if ! agent_is_running "$agent"; then
        plist=$(agent_plist "$agent") || return 1
        output=$(/bin/launchctl load -w "$plist" 2>&1) || log WARN "launchctl load reported an error for $agent: $output"
    fi
    attempt=0
    while ! agent_is_running "$agent" && [ "$attempt" -lt 10 ]; do
        /bin/sleep 1
        attempt=$((attempt + 1))
    done
    if ! agent_is_running "$agent"; then
        log ERROR "Agent service did not start: $agent"
        return 1
    fi
    log INFO "Agent started: $agent"
    return 0
}

write_recovery_marker() {
    local temporary agent
    if [ "$DRY_RUN" -eq 1 ]; then
        RECOVERY_ACTIVE=1
        return 0
    fi
    if [ -d "$RECOVERY_DIR" ]; then
        log ERROR "A recovery marker already exists at $RECOVERY_DIR"
        return 1
    fi
    temporary="${STATE_DIR}/recovery.$$"
    /bin/mkdir "$temporary" || return 1
    /usr/bin/printf '%s\n' "$$" > "${temporary}/owner-pid"
    /bin/date '+%s' > "${temporary}/started-epoch"
    : > "${temporary}/agents"
    for agent in "${DISCOVERED_AGENTS[@]}"; do
        /usr/bin/printf '%s\n' "$agent" >> "${temporary}/agents"
    done
    /usr/bin/touch "${temporary}/heartbeat"
    /bin/mv "$temporary" "$RECOVERY_DIR" || return 1
    RECOVERY_ACTIVE=1
}

heartbeat_loop() {
    local owner=$1
    while /bin/kill -0 "$owner" >/dev/null 2>&1 && [ -d "$RECOVERY_DIR" ]; do
        /usr/bin/touch "${RECOVERY_DIR}/heartbeat" 2>/dev/null || true
        /bin/sleep 5
    done
}

start_heartbeat() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    heartbeat_loop "$$" &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [ -n "$HEARTBEAT_PID" ]; then
        /bin/kill "$HEARTBEAT_PID" >/dev/null 2>&1 || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

remove_recovery_marker() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -d "$RECOVERY_DIR" ] || return 0
    /bin/rm -f "${RECOVERY_DIR}/owner-pid" "${RECOVERY_DIR}/started-epoch" "${RECOVERY_DIR}/agents" "${RECOVERY_DIR}/heartbeat"
    /bin/rmdir "$RECOVERY_DIR" 2>/dev/null || return 1
}

restart_agents_from_marker() {
    local agent failed
    failed=0
    if [ "$DRY_RUN" -eq 1 ]; then
        for agent in "${DISCOVERED_AGENTS[@]}"; do
            start_agent "$agent" || failed=1
        done
    elif [ -f "${RECOVERY_DIR}/agents" ]; then
        while IFS= read -r agent; do
            [ -n "$agent" ] || continue
            if [ ! -x "${agent}/svc.sh" ] || [ ! -f "${agent}/.service" ]; then
                log ERROR "Recovery entry is not an installed agent: $agent"
                failed=1
                continue
            fi
            start_agent "$agent" || failed=1
        done < "${RECOVERY_DIR}/agents"
    elif [ "$RECOVERY_ACTIVE" -eq 1 ] && [ "${#DISCOVERED_AGENTS[@]}" -gt 0 ]; then
        log WARN "Recovery marker disappeared. Restarting every agent from current discovery."
        for agent in "${DISCOVERED_AGENTS[@]}"; do
            start_agent "$agent" || failed=1
        done
    fi
    if [ "$failed" -eq 0 ]; then
        remove_recovery_marker || failed=1
    fi
    if [ "$failed" -eq 0 ]; then
        RECOVERY_ACTIVE=0
        log INFO "All agent services are running."
        return 0
    fi
    log ERROR "One or more agents could not be restarted. The watchdog will retry."
    return 1
}

recovery_owner_is_active() {
    local owner command heartbeat now modified started
    [ -f "${RECOVERY_DIR}/owner-pid" ] || return 1
    owner=$(/usr/bin/sed -n '1p' "${RECOVERY_DIR}/owner-pid")
    case "$owner" in *[!0-9]*|'') return 1 ;; esac
    command=$(/bin/ps -p "$owner" -o command= 2>/dev/null || true)
    case "$command" in
        *build-agent-maintenance.sh*) ;;
        *) return 1 ;;
    esac
    now=$(/bin/date '+%s')
    started=$(/usr/bin/sed -n '1p' "${RECOVERY_DIR}/started-epoch" 2>/dev/null || /usr/bin/printf '0')
    case "$started" in *[!0-9]*|'') started=0 ;; esac
    if [ $((now - started)) -ge "$WATCHDOG_HARD_TIMEOUT_SECONDS" ]; then
        return 1
    fi
    heartbeat="${RECOVERY_DIR}/heartbeat"
    [ -f "$heartbeat" ] || return 1
    modified=$(/usr/bin/stat -f '%m' "$heartbeat" 2>/dev/null || /usr/bin/printf '0')
    [ $((now - modified)) -lt 60 ]
}

recover_if_abandoned() {
    [ -d "$RECOVERY_DIR" ] || return 0
    if recovery_owner_is_active; then
        log INFO "Another maintenance process owns the active recovery marker."
        return 2
    fi
    log WARN "Recovering agents from an abandoned maintenance run."
    RECOVERY_ACTIVE=1
    restart_agents_from_marker
}

drain_and_stop_agents() {
    local deadline now remaining agent all_stopped
    deadline=$(( $(/bin/date '+%s') + BUILD_DRAIN_SECONDS ))
    pending=("${DISCOVERED_AGENTS[@]}")
    notify_user "Waiting up to ${BUILD_DRAIN_SECONDS} seconds for active builds before stopping agents."
    while [ "${#pending[@]}" -gt 0 ]; do
        next_pending=()
        for agent in "${pending[@]}"; do
            if ! agent_is_running "$agent"; then
                log INFO "Agent is already stopped: $agent"
            elif ! agent_has_worker "$agent"; then
                stop_agent "$agent" || next_pending+=("$agent")
            else
                next_pending+=("$agent")
            fi
        done
        pending=("${next_pending[@]}")
        [ "${#pending[@]}" -eq 0 ] && break
        now=$(/bin/date '+%s')
        remaining=$((deadline - now))
        [ "$remaining" -le 0 ] && break
        log INFO "Waiting for ${#pending[@]} busy agent(s). ${remaining} second(s) remain."
        /bin/sleep 1
    done
    for agent in "${pending[@]}"; do
        log WARN "Drain deadline reached. Stopping busy agent: $agent"
        stop_agent "$agent" || true
    done
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    all_stopped=0
    for agent in "${DISCOVERED_AGENTS[@]}"; do
        if agent_is_running "$agent"; then
            log ERROR "Cleanup blocked because this agent is still running: $agent"
            all_stopped=1
        fi
    done
    return "$all_stopped"
}

recovery_is_owned_by_current_process() {
    local owner
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -f "${RECOVERY_DIR}/owner-pid" ] || return 1
    owner=$(/usr/bin/sed -n '1p' "${RECOVERY_DIR}/owner-pid" 2>/dev/null || true)
    [ "$owner" = "$$" ]
}

all_agents_are_stopped() {
    local agent
    [ "$DRY_RUN" -eq 1 ] && return 0
    for agent in "${DISCOVERED_AGENTS[@]}"; do
        agent_is_running "$agent" && return 1
    done
    return 0
}

simulator_list_has_booted_device() {
    case "$1" in
        *' (Booted)'*) return 0 ;;
        *) return 1 ;;
    esac
}

shutdown_booted_simulators() {
    local devices output deadline remaining
    if ! devices=$(/usr/bin/xcrun simctl list devices 2>&1); then
        log ERROR "Could not list Simulator devices: $devices"
        return 1
    fi
    if ! simulator_list_has_booted_device "$devices"; then
        log INFO "No booted Simulator devices were found."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log DRYRUN "Would shut down all booted Simulator devices."
        return 0
    fi
    log INFO "Shutting down all booted Simulator devices."
    if ! output=$(/usr/bin/xcrun simctl shutdown all 2>&1); then
        log ERROR "simctl shutdown all failed: $output"
        return 1
    fi
    deadline=$(( $(/bin/date '+%s') + SIMULATOR_SHUTDOWN_WAIT_SECONDS ))
    while :; do
        if ! devices=$(/usr/bin/xcrun simctl list devices 2>&1); then
            log ERROR "Could not verify Simulator shutdown: $devices"
            return 1
        fi
        if ! simulator_list_has_booted_device "$devices"; then
            log INFO "All Simulator devices are shut down."
            return 0
        fi
        remaining=$((deadline - $(/bin/date '+%s')))
        [ "$remaining" -le 0 ] && break
        log INFO "Waiting for Simulator devices to shut down. ${remaining} second(s) remain."
        /bin/sleep 1
    done
    log ERROR "One or more Simulator devices remained booted after ${SIMULATOR_SHUTDOWN_WAIT_SECONDS} seconds."
    return 1
}

classify_process_command() {
    local command=$1 executable agent
    executable=${command%% *}
    executable=${executable##*/}
    case "$executable" in
        Agent.Worker) /usr/bin/printf '%s\n' 'Azure Agent.Worker'; return 0 ;;
        node|node[0-9]*|npm|npx|yarn|corepack) /usr/bin/printf '%s\n' 'Node.js'; return 0 ;;
        watchman) /usr/bin/printf '%s\n' 'Watchman'; return 0 ;;
        adb|emulator|qemu-system-*) /usr/bin/printf '%s\n' 'Android tooling'; return 0 ;;
        xcodebuild|XCBBuildService|SWBBuildService|ibtool|actool) /usr/bin/printf '%s\n' 'Xcode build'; return 0 ;;
    esac
    case "$command" in
        *GradleDaemon*|*org.gradle*|*gradlew*) /usr/bin/printf '%s\n' 'Gradle'; return 0 ;;
        *'/Android/sdk/ndk/'*) /usr/bin/printf '%s\n' 'Android NDK'; return 0 ;;
    esac
    for agent in "${DISCOVERED_AGENTS[@]}"; do
        case "$command" in
            *"${agent}/_work/"*) /usr/bin/printf '%s\n' 'agent work process'; return 0 ;;
        esac
    done
    return 1
}

snapshot_and_select_processes() {
    local snapshot=$1 targets=$2 line pid ppid user command category current_user
    current_user=$(/usr/bin/id -un)
    : > "$snapshot"
    : > "$targets"
    while IFS= read -r line; do
        while [ "${line# }" != "$line" ]; do line=${line# }; done
        pid=${line%% *}
        line=${line#* }
        while [ "${line# }" != "$line" ]; do line=${line# }; done
        ppid=${line%% *}
        line=${line#* }
        while [ "${line# }" != "$line" ]; do line=${line# }; done
        user=${line%% *}
        command=${line#* }
        while [ "${command# }" != "$command" ]; do command=${command# }; done
        case "$pid:$ppid" in *[!0-9:]*|:*) continue ;; esac
        /usr/bin/printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$user" "$command" >> "$snapshot"
        [ "$user" = "$current_user" ] || continue
        [ "$pid" -ne "$$" ] || continue
        category=$(classify_process_command "$command" 2>/dev/null) || continue
        /usr/bin/printf '%s\t%s\n' "$pid" "$category" >> "$targets"
    done < <(/bin/ps -axo pid=,ppid=,user=,command=)
}

expand_target_descendants() {
    local snapshot=$1 targets=$2 additions normalized count
    additions="${targets}.new"
    normalized="${targets}.normalized"
    while :; do
        /usr/bin/awk -F '\t' 'NR==FNR { wanted[$1]=1; next } wanted[$2] && !wanted[$1] { print $1 "\tdescendant" }' "$targets" "$snapshot" > "$additions"
        count=$(/usr/bin/wc -l < "$additions" | /usr/bin/tr -d ' ')
        [ "$count" -eq 0 ] && break
        /bin/cat "$additions" >> "$targets"
        /usr/bin/sort -n -k1,1 "$targets" | /usr/bin/awk -F '\t' '!seen[$1]++' > "$normalized"
        /bin/mv "$normalized" "$targets"
    done
    /bin/rm -f "$additions" "$normalized"
}

process_is_alive() {
    /bin/kill -0 "$1" >/dev/null 2>&1
}

process_identity_matches_snapshot() {
    local pid=$1 snapshot=$2 expected current
    expected=$(/usr/bin/awk -F '\t' -v wanted="$pid" '$1 == wanted { print $4; exit }' "$snapshot")
    [ -n "$expected" ] || return 1
    current=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
    [ "$current" = "$expected" ]
}

terminate_build_processes() {
    local snapshot targets rescan_snapshot rescan_targets pid category command remaining deadline survivors
    snapshot="${STATE_DIR}/process-snapshot.$$"
    targets="${STATE_DIR}/process-targets.$$"
    if ! recovery_is_owned_by_current_process || ! all_agents_are_stopped; then
        log ERROR "Process cleanup blocked because the recovery lease is missing or an agent is running."
        return 1
    fi
    snapshot_and_select_processes "$snapshot" "$targets"
    expand_target_descendants "$snapshot" "$targets"
    if [ ! -s "$targets" ]; then
        log INFO "No stale build processes matched the cleanup rules."
        /bin/rm -f "$snapshot" "$targets"
        return 0
    fi
    if ! recovery_is_owned_by_current_process || ! all_agents_are_stopped; then
        log ERROR "Process cleanup aborted because the recovery lease changed or an agent restarted."
        /bin/rm -f "$snapshot" "$targets"
        return 1
    fi
    while IFS=$'\t' read -r pid category; do
        command=$(/usr/bin/awk -F '\t' -v wanted="$pid" '$1 == wanted { print $4; exit }' "$snapshot")
        command=${command%% *}
        log INFO "Selected PID $pid (${category}, ${command##*/})"
    done < "$targets"
    if [ "$DRY_RUN" -eq 1 ]; then
        log DRYRUN "Would send TERM and then KILL if needed to $(/usr/bin/wc -l < "$targets" | /usr/bin/tr -d ' ') process(es)."
        /bin/rm -f "$snapshot" "$targets"
        return 0
    fi
    while IFS=$'\t' read -r pid category; do
        if process_identity_matches_snapshot "$pid" "$snapshot"; then
            /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
        else
            log INFO "Skipped PID $pid because it exited or its identity changed before TERM."
        fi
    done < "$targets"
    deadline=$(( $(/bin/date '+%s') + PROCESS_TERM_WAIT_SECONDS ))
    while :; do
        survivors=0
        while IFS=$'\t' read -r pid category; do
            if process_is_alive "$pid" && process_identity_matches_snapshot "$pid" "$snapshot"; then
                survivors=$((survivors + 1))
            fi
        done < "$targets"
        [ "$survivors" -eq 0 ] && break
        remaining=$((deadline - $(/bin/date '+%s')))
        [ "$remaining" -le 0 ] && break
        log INFO "Waiting for $survivors process(es) to exit after TERM. ${remaining} second(s) remain."
        /bin/sleep 1
    done
    while IFS=$'\t' read -r pid category; do
        if process_is_alive "$pid" && process_identity_matches_snapshot "$pid" "$snapshot"; then
            log WARN "Sending KILL to remaining PID $pid ($category)."
            /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
        fi
    done < "$targets"
    /bin/sleep 1
    rescan_snapshot="${snapshot}.rescan"
    rescan_targets="${targets}.rescan"
    snapshot_and_select_processes "$rescan_snapshot" "$rescan_targets"
    expand_target_descendants "$rescan_snapshot" "$rescan_targets"
    if [ -s "$rescan_targets" ]; then
        log WARN "A final scan found $(/usr/bin/wc -l < "$rescan_targets" | /usr/bin/tr -d ' ') remaining or newly spawned process(es)."
        while IFS=$'\t' read -r pid category; do
            if process_identity_matches_snapshot "$pid" "$rescan_snapshot"; then
                /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
            fi
        done < "$rescan_targets"
        /bin/sleep 1
    fi
    /bin/rm -f "$rescan_snapshot" "$rescan_targets"
    /bin/rm -f "$snapshot" "$targets"
    return 0
}

validate_xcode_derived_data_directory() {
    local home=$1 derived_data=$2 canonical_home canonical_parent parent
    [ "${derived_data##*/}" = 'DerivedData' ] || return 1
    [ ! -L "$derived_data" ] || return 1
    canonical_home=$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$home") || return 1
    parent=$(/usr/bin/dirname "$derived_data")
    canonical_parent=$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$parent") || return 1
    case "$canonical_home" in /|'') return 1 ;; esac
    [ "$canonical_parent" = "${canonical_home}/Library/Developer/Xcode" ]
}

clean_xcode_derived_data() {
    local attempt error_line
    if [ ! -e "$XCODE_DERIVED_DATA_DIR" ] && [ ! -L "$XCODE_DERIVED_DATA_DIR" ]; then
        log INFO "Xcode DerivedData directory does not exist: $XCODE_DERIVED_DATA_DIR"
        return 0
    fi
    if ! recovery_is_owned_by_current_process || ! all_agents_are_stopped; then
        log ERROR "Xcode DerivedData cleanup blocked because the recovery lease is missing or an agent is running."
        return 1
    fi
    if ! validate_xcode_derived_data_directory "$HOME" "$XCODE_DERIVED_DATA_DIR"; then
        log ERROR "Refusing unsafe Xcode DerivedData path: $XCODE_DERIVED_DATA_DIR"
        return 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log DRYRUN "Would remove Xcode DerivedData directory: $XCODE_DERIVED_DATA_DIR"
        return 0
    fi
    log WARN "Removing Xcode DerivedData directory: $XCODE_DERIVED_DATA_DIR"
    attempt=1
    while [ "$attempt" -le "$WORK_DELETE_RETRIES" ]; do
        /bin/rm -rf -- "$XCODE_DERIVED_DATA_DIR" 2>&1 | while IFS= read -r error_line; do log WARN "$error_line"; done
        [ ! -e "$XCODE_DERIVED_DATA_DIR" ] && [ ! -L "$XCODE_DERIVED_DATA_DIR" ] && break
        if [ "$attempt" -lt "$WORK_DELETE_RETRIES" ]; then
            log WARN "Xcode DerivedData still exists. Retrying in ${WORK_DELETE_RETRY_SECONDS} seconds."
            /bin/sleep "$WORK_DELETE_RETRY_SECONDS"
        fi
        attempt=$((attempt + 1))
    done
    if [ -e "$XCODE_DERIVED_DATA_DIR" ] || [ -L "$XCODE_DERIVED_DATA_DIR" ]; then
        log ERROR "Could not remove Xcode DerivedData after ${WORK_DELETE_RETRIES} attempts: $XCODE_DERIVED_DATA_DIR"
        return 1
    fi
    log INFO "Xcode DerivedData was removed."
    return 0
}

free_disk_percent() {
    /bin/df -Pk "$1" | /usr/bin/awk 'NR == 2 { gsub(/%/, "", $5); print 100 - $5 }'
}

validate_work_directory() {
    local agent=$1 work=$2 canonical_agent canonical_parent parent
    [ "${work##*/}" = '_work' ] || return 1
    [ ! -L "$work" ] || return 1
    canonical_agent=$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$agent") || return 1
    parent=$(/usr/bin/dirname "$work")
    canonical_parent=$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$parent") || return 1
    [ "$canonical_parent" = "$canonical_agent" ] || return 1
    case "$canonical_agent" in /|"${HOME}"|'') return 1 ;; esac
    return 0
}

clean_work_directories_if_low_disk() {
    local agent free minimum work after attempt
    minimum=100
    for agent in "${DISCOVERED_AGENTS[@]}"; do
        free=$(free_disk_percent "$agent")
        case "$free" in *[!0-9]*|'') log ERROR "Could not read disk free percentage for $agent"; return 1 ;; esac
        [ "$free" -lt "$minimum" ] && minimum=$free
    done
    log INFO "Disk free space is ${minimum}%. Required minimum is ${MINIMUM_FREE_DISK_PERCENT}%."
    if [ "$minimum" -ge "$MINIMUM_FREE_DISK_PERCENT" ]; then
        return 0
    fi
    if ! recovery_is_owned_by_current_process || ! all_agents_are_stopped; then
        log ERROR "Work-directory cleanup blocked because the recovery lease is missing or an agent is running."
        return 1
    fi
    log WARN "Disk free space is below the limit. Every discovered agent _work directory will be removed."
    for agent in "${DISCOVERED_AGENTS[@]}"; do
        if ! recovery_is_owned_by_current_process || ! all_agents_are_stopped; then
            log ERROR "Work-directory cleanup aborted because the recovery lease changed or an agent restarted."
            return 1
        fi
        work="${agent}/_work"
        [ -e "$work" ] || { log INFO "Work directory does not exist: $work"; continue; }
        if ! validate_work_directory "$agent" "$work"; then
            log ERROR "Refusing unsafe work directory path: $work"
            return 1
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            log DRYRUN "Would remove directory: $work"
        else
            log WARN "Removing directory: $work"
            attempt=1
            while [ "$attempt" -le "$WORK_DELETE_RETRIES" ]; do
                /bin/rm -rf -- "$work" 2>&1 | while IFS= read -r error_line; do log WARN "$error_line"; done
                [ ! -e "$work" ] && break
                if [ "$attempt" -lt "$WORK_DELETE_RETRIES" ]; then
                    log WARN "Work directory still exists. Retrying in ${WORK_DELETE_RETRY_SECONDS} seconds: $work"
                    /bin/sleep "$WORK_DELETE_RETRY_SECONDS"
                fi
                attempt=$((attempt + 1))
            done
            if [ -e "$work" ]; then
                log ERROR "Could not remove work directory after ${WORK_DELETE_RETRIES} attempts: $work"
                return 1
            fi
        fi
    done
    if [ "$DRY_RUN" -eq 1 ]; then
        log DRYRUN "Would recheck disk free space after deleting the work directories."
        return 0
    fi
    after=$(free_disk_percent "${DISCOVERED_AGENTS[0]}")
    log INFO "Disk free space after work-directory cleanup: ${after}%."
}

acquire_maintenance_lock() {
    if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
        /usr/bin/printf '%s\n' "$$" > "${LOCK_DIR}/pid"
        LOCK_ACQUIRED=1
        return 0
    fi
    local owner command
    owner=$(/usr/bin/sed -n '1p' "${LOCK_DIR}/pid" 2>/dev/null || true)
    case "$owner" in
        *[!0-9]*|'') command="" ;;
        *) command=$(/bin/ps -p "$owner" -o command= 2>/dev/null || true) ;;
    esac
    case "$command" in
        *build-agent-maintenance.sh*) ;;
        *)
            log WARN "Removing a stale maintenance lock owned by PID ${owner:-unknown}."
            /bin/rm -f "${LOCK_DIR}/pid"
            /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
            if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
                /usr/bin/printf '%s\n' "$$" > "${LOCK_DIR}/pid"
                LOCK_ACQUIRED=1
                return 0
            fi
            ;;
    esac
    log WARN "Another maintenance run owns $LOCK_DIR."
    return 1
}

release_maintenance_lock() {
    local owner
    [ "$LOCK_ACQUIRED" -eq 1 ] || return 0
    if [ ! -d "$LOCK_DIR" ]; then
        LOCK_ACQUIRED=0
        return 0
    fi
    owner=$(/usr/bin/sed -n '1p' "${LOCK_DIR}/pid" 2>/dev/null || true)
    if [ "$owner" != "$$" ]; then
        log ERROR "Refusing to release a maintenance lock now owned by PID ${owner:-unknown}."
        LOCK_ACQUIRED=0
        return 1
    fi
    /bin/rm -f "${LOCK_DIR}/pid"
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_ACQUIRED=0
}

run_maintenance() {
    local failed recovery_result
    start_run_log
    log INFO "Maintenance run started."
    if ! discover_agents; then
        log ERROR "No installed Azure agents were found below: ${AGENT_SEARCH_ROOTS[*]}"
        return 1
    fi
    log INFO "Discovered ${#DISCOVERED_AGENTS[@]} agent(s)."
    if ! acquire_maintenance_lock; then
        return 1
    fi
    if [ -d "$RECOVERY_DIR" ]; then
        recover_if_abandoned
        recovery_result=$?
        if [ "$recovery_result" -ne 0 ]; then
            release_maintenance_lock
            return 1
        fi
    fi
    if ! write_recovery_marker; then
        log ERROR "Could not create the recovery marker. No agents were stopped."
        release_maintenance_lock
        return 1
    fi
    start_heartbeat
    failed=0
    if ! drain_and_stop_agents; then
        failed=1
    elif ! shutdown_booted_simulators; then
        failed=1
    elif ! terminate_build_processes; then
        failed=1
    elif ! clean_xcode_derived_data; then
        failed=1
    elif ! clean_work_directories_if_low_disk; then
        failed=1
    fi
    stop_heartbeat
    restart_agents_from_marker || failed=1
    release_maintenance_lock
    if [ "$failed" -eq 0 ]; then
        notify_user "Maintenance finished and all build agents are running."
        log INFO "Maintenance run completed successfully."
        return 0
    fi
    notify_user "Maintenance had errors. The recovery watchdog will keep retrying stopped agents."
    log ERROR "Maintenance run completed with errors."
    return 1
}

on_exit() {
    local code=$?
    trap - EXIT HUP INT TERM
    stop_heartbeat
    if [ "$RECOVERY_ACTIVE" -eq 1 ]; then
        log WARN "Process exit detected during maintenance. Restarting agents from the recovery marker."
        restart_agents_from_marker || true
    fi
    release_maintenance_lock
    exit "$code"
}

handle_signal() {
    log WARN "Termination signal received."
    exit 1
}

schedule_slot_due() {
    local now slot normalized key last
    now=$(/bin/date '+%H%M')
    for slot in "${MAINTENANCE_TIMES[@]}"; do
        normalized=$(normalize_schedule_time "$slot") || continue
        [ "$now" = "$normalized" ] || continue
        key="$(/bin/date '+%Y-%m-%d'):${slot}"
        last=$(/usr/bin/sed -n '1p' "$SCHEDULE_STATE_FILE" 2>/dev/null || true)
        [ "$last" = "$key" ] && return 1
        DUE_SCHEDULE_KEY=$key
        return 0
    done
    return 1
}

run_daemon() {
    ensure_runtime_directories
    LOG_FILE="${HOME}/Library/Logs/${PROGRAM_NAME}/scheduler.log"
    /bin/mkdir -p "${HOME}/Library/Logs/${PROGRAM_NAME}"
    log INFO "Scheduler started. Maintenance times: ${MAINTENANCE_TIMES[*]}."
    validate_schedule || return 1
    if [ -d "$RECOVERY_DIR" ]; then
        recover_if_abandoned || true
    fi
    while :; do
        if schedule_slot_due; then
            /usr/bin/printf '%s\n' "$DUE_SCHEDULE_KEY" > "$SCHEDULE_STATE_FILE"
            run_maintenance || true
            LOG_FILE="${HOME}/Library/Logs/${PROGRAM_NAME}/scheduler.log"
        fi
        /bin/sleep "$SCHEDULER_POLL_SECONDS"
    done
}

usage() {
    /usr/bin/printf '%s\n' 'Usage: build-agent-maintenance.sh --daemon | --run-once [--dry-run] | --recover'
}

main() {
    local mode="" argument
    for argument in "$@"; do
        case "$argument" in
            --daemon|--run-once|--recover) [ -z "$mode" ] || { usage; return 2; }; mode=$argument ;;
            --dry-run) DRY_RUN=1 ;;
            *) usage; return 2 ;;
        esac
    done
    [ -n "$mode" ] || { usage; return 2; }
    validate_dependencies || return 1
    ensure_runtime_directories
    trap on_exit EXIT
    trap handle_signal HUP INT TERM
    case "$mode" in
        --daemon) run_daemon ;;
        --run-once) run_maintenance ;;
        --recover)
            start_run_log
            discover_agents || true
            if [ -d "$RECOVERY_DIR" ]; then
                RECOVERY_ACTIVE=1
                restart_agents_from_marker
            else
                log INFO "No recovery marker exists."
            fi
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
