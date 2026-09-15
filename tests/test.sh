#!/bin/bash

set -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "${ROOT}/scripts/build-agent-maintenance.sh"

failures=0

assert_equal() {
    local expected=$1 actual=$2 description=$3
    if [ "$expected" != "$actual" ]; then
        /usr/bin/printf 'FAIL: %s. Expected <%s>, got <%s>.\n' "$description" "$expected" "$actual" >&2
        failures=$((failures + 1))
    else
        /usr/bin/printf 'PASS: %s\n' "$description"
    fi
}

assert_success() {
    local description=$1
    shift
    if "$@"; then
        /usr/bin/printf 'PASS: %s\n' "$description"
    else
        /usr/bin/printf 'FAIL: %s\n' "$description" >&2
        failures=$((failures + 1))
    fi
}

assert_failure() {
    local description=$1
    shift
    if "$@"; then
        /usr/bin/printf 'FAIL: %s\n' "$description" >&2
        failures=$((failures + 1))
    else
        /usr/bin/printf 'PASS: %s\n' "$description"
    fi
}

assert_equal '0000' "$(normalize_schedule_time 2400)" '2400 maps to midnight'
assert_equal '0230' "$(normalize_schedule_time 0230)" '0230 remains 02:30'
assert_equal '2100' "$(normalize_schedule_time 2100)" '2100 remains 21:00'
assert_failure '2460 is rejected' normalize_schedule_time 2460
assert_failure '2401 is rejected' normalize_schedule_time 2401

assert_success 'manual full-clean arguments are accepted' parse_arguments --run-once --full-clean
assert_equal '--run-once' "$MODE" 'manual full-clean uses run-once mode'
assert_equal '1' "$FULL_CLEAN" 'manual full-clean enables forced cleanup'
assert_failure 'full-clean is rejected for daemon mode' parse_arguments --daemon --full-clean
assert_success 'ordinary run-once arguments remain accepted' parse_arguments --run-once
assert_equal '0' "$FULL_CLEAN" 'ordinary run-once keeps disk-threshold cleanup'

assert_failure 'disk threshold skips work cleanup at 20 percent' work_cleanup_is_required 20 0 20
assert_success 'full-clean forces work cleanup at 20 percent' work_cleanup_is_required 20 1 20

DISCOVERED_AGENTS=("/Users/example/azba/agent-01")
assert_equal 'Node.js' "$(classify_process_command '/opt/homebrew/bin/node app.js')" 'Node.js is selected'
assert_equal 'Watchman' "$(classify_process_command '/opt/homebrew/bin/watchman --foreground')" 'Watchman is selected'
assert_equal 'Android tooling' "$(classify_process_command '/Users/example/Library/Android/sdk/platform-tools/adb -L tcp:5037 fork-server')" 'adb is selected'
assert_equal 'Android NDK' "$(classify_process_command '/Users/example/Library/Android/sdk/ndk/27/bin/clang++ source.cpp')" 'NDK compiler is selected'
assert_equal 'Gradle' "$(classify_process_command '/usr/bin/java org.gradle.launcher.daemon.bootstrap.GradleDaemon')" 'Gradle daemon is selected'
assert_equal 'Xcode build' "$(classify_process_command '/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild archive')" 'xcodebuild is selected'
assert_equal 'Azure Agent.Worker' "$(classify_process_command '/Users/example/azba/agent-01/bin.5.277.0/Agent.Worker spawnclient 184 190')" 'orphaned Agent.Worker is selected'
assert_equal 'agent work process' "$(classify_process_command '/bin/bash /Users/example/azba/agent-01/_work/1/s/build.sh')" 'agent worktree process is selected'
assert_failure 'unrelated Java is not selected' classify_process_command '/usr/bin/java -jar unrelated-service.jar'
assert_failure 'Docker is not selected' classify_process_command '/Applications/Docker.app/Contents/MacOS/com.docker.backend'

assert_success 'booted simulator is detected' simulator_list_has_booted_device '    iPhone 17 Pro (A1B2C3) (Booted)'
assert_failure 'shutdown simulator is ignored' simulator_list_has_booted_device '    iPhone 17 Pro (A1B2C3) (Shutdown)'
assert_success 'versioned worker path marks its agent busy' command_is_agent_worker '/Users/example/azba/agent-01' '/Users/example/azba/agent-01/bin.5.277.0/Agent.Worker spawnclient 184 190'
assert_failure 'another agent worker does not mark this agent busy' command_is_agent_worker '/Users/example/azba/agent-01' '/Users/example/azba/agent-02/bin.5.277.0/Agent.Worker spawnclient 184 190'

temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/bama-test.XXXXXX")
trap '/bin/rm -rf -- "$temporary"' EXIT

xcode_home="${temporary}/home"
xcode_parent="${xcode_home}/Library/Developer/Xcode"
xcode_derived_data="${xcode_parent}/DerivedData"
/bin/mkdir -p "$xcode_derived_data"
assert_success 'standard Xcode DerivedData path is accepted' validate_xcode_derived_data_directory "$xcode_home" "$xcode_derived_data"
assert_failure 'a different Xcode directory is rejected' validate_xcode_derived_data_directory "$xcode_home" "${xcode_parent}/Archives"
/bin/rm -rf "$xcode_derived_data"
/bin/ln -s /tmp "$xcode_derived_data"
assert_failure 'symlinked Xcode DerivedData path is rejected' validate_xcode_derived_data_directory "$xcode_home" "$xcode_derived_data"
/bin/rm "$xcode_derived_data"
/bin/mkdir -p "$xcode_derived_data"
: > "${xcode_derived_data}/build-cache"
saved_home=$HOME
saved_recovery_dir=$RECOVERY_DIR
saved_derived_data_dir=$XCODE_DERIVED_DATA_DIR
HOME=$xcode_home
RECOVERY_DIR="${temporary}/derived-data-recovery"
XCODE_DERIVED_DATA_DIR=$xcode_derived_data
DISCOVERED_AGENTS=()
/bin/mkdir -p "$RECOVERY_DIR"
/usr/bin/printf '%s\n' "$$" > "${RECOVERY_DIR}/owner-pid"
assert_success 'Xcode DerivedData cleanup removes the guarded directory' clean_xcode_derived_data
assert_failure 'Xcode DerivedData directory no longer exists' test -e "$xcode_derived_data"
HOME=$saved_home
RECOVERY_DIR=$saved_recovery_dir
XCODE_DERIVED_DATA_DIR=$saved_derived_data_dir

agent="${temporary}/agent"
/bin/mkdir -p "${agent}/_work"
assert_success 'direct _work path is accepted' validate_work_directory "$agent" "${agent}/_work"
/bin/rm -rf "${agent}/_work"
/bin/ln -s /tmp "${agent}/_work"
assert_failure 'symlinked _work path is rejected' validate_work_directory "$agent" "${agent}/_work"

agent_root="${temporary}/agents"
for name in agent-01 agent-02; do
    /bin/mkdir -p "${agent_root}/${name}"
    : > "${agent_root}/${name}/.agent"
    : > "${agent_root}/${name}/.service"
    : > "${agent_root}/${name}/svc.sh"
    /bin/chmod 700 "${agent_root}/${name}/svc.sh"
done
AGENT_SEARCH_ROOTS=("$agent_root")
assert_success 'agent discovery finds valid installations' discover_agents
assert_equal '2' "${#DISCOVERED_AGENTS[@]}" 'agent discovery returns both installations'

snapshot="${temporary}/snapshot"
targets="${temporary}/targets"
/usr/bin/printf '10\t1\texample\tparent\n11\t10\texample\tchild\n12\t11\texample\tgrandchild\n20\t1\texample\tunrelated\n' > "$snapshot"
/usr/bin/printf '10\tNode.js\n' > "$targets"
expand_target_descendants "$snapshot" "$targets"
assert_equal '3' "$(/usr/bin/wc -l < "$targets" | /usr/bin/tr -d ' ')" 'target expansion adds every descendant'
assert_equal '10 11 12 ' "$(/usr/bin/awk -F '\t' '{ printf "%s ", $1 }' "$targets")" 'target expansion excludes unrelated processes'

STATE_DIR="${temporary}/heartbeat-state"
RECOVERY_DIR="${STATE_DIR}/recovery"
/bin/mkdir -p "$STATE_DIR"
DISCOVERED_AGENTS=()
assert_success 'recovery marker can be created' write_recovery_marker
heartbeat_before=$(/usr/bin/stat -f '%m' "${RECOVERY_DIR}/heartbeat")
start_heartbeat
/bin/sleep 6
heartbeat_after=$(/usr/bin/stat -f '%m' "${RECOVERY_DIR}/heartbeat")
stop_heartbeat
if [ "$heartbeat_after" -gt "$heartbeat_before" ]; then
    /usr/bin/printf 'PASS: heartbeat advances while maintenance is active\n'
else
    /usr/bin/printf 'FAIL: heartbeat did not advance\n' >&2
    failures=$((failures + 1))
fi
remove_recovery_marker

if [ "$failures" -ne 0 ]; then
    /usr/bin/printf '%s test(s) failed.\n' "$failures" >&2
    exit 1
fi

/usr/bin/printf 'All tests passed.\n'
