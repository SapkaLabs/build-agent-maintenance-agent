# Build agent maintenance

Scheduled maintenance for self-hosted Azure Pipelines agents on the Inphiz Mac mini.

The service runs as the same macOS user as the agents. It drains and stops every discovered agent,
removes stale build processes, checks free disk space, and starts every agent again. A separate
launchd watchdog starts the agents if the maintenance process exits before recovery.

## Default schedule and limits

The constants are at the top of
[`scripts/build-agent-maintenance.sh`](scripts/build-agent-maintenance.sh):

```bash
MAINTENANCE_TIMES=("2100" "2400" "0230")
MINIMUM_FREE_DISK_PERCENT=20
BUILD_DRAIN_SECONDS=30
SIMULATOR_SHUTDOWN_WAIT_SECONDS=30
```

`2400` means midnight. Times use the Mac's local time. The daemon records completed slots, so a
launchd restart during the same minute does not run maintenance twice.

## What one maintenance run does

1. Finds configured Azure agents below `~/azba` by locating `.agent`, `.service`, and `svc.sh`.
2. Writes a recovery marker before stopping anything.
3. Waits up to 30 seconds for active `Agent.Worker` processes. It stops each idle agent immediately.
4. Confirms every agent service is stopped. Cleanup does not run if this check fails.
5. Shuts down all booted Apple Simulator devices and waits up to 30 seconds for shutdown.
6. Sends `TERM`, waits up to 10 seconds, then sends `KILL` to remaining targeted processes.
7. Removes `~/Library/Developer/Xcode/DerivedData` after validating the path is not a symlink.
8. Deletes each agent's `_work` directory only when disk free space is below 20 percent.
9. Starts every discovered agent and removes the recovery marker after all starts succeed.

The cleanup targets orphaned Azure `Agent.Worker` processes, all processes whose command belongs to
an agent `_work` directory, all Node.js and Watchman processes, Android build and emulator
processes, Gradle daemons, Xcode build processes, and compiler processes tied to an agent worktree
or Android NDK.

Each run writes `~/Documents/BuildAgentMaintenance/maintenance-YYYYMMDD-HHMMSS.log`. launchd output
goes to `~/Library/Logs/BuildAgentMaintenance`.

## Failure recovery

Normal errors and termination signals run the restart code through an exit trap. A second launchd
job checks the recovery marker every 15 seconds. If the main process crashes, receives `SIGKILL`, or
the Mac reboots during maintenance, the watchdog starts every agent listed in the marker. It keeps
the marker when any start fails and retries on its next pass.

The watchdog also treats maintenance lasting more than one hour as failed. Change
`WATCHDOG_HARD_TIMEOUT_SECONDS` in both scripts if `_work` deletion can legitimately take longer.

## Install on the Mac

Run this as the agent user, without `sudo`:

```bash
/bin/bash scripts/install.sh
```

The installer copies the runtime scripts to
`~/Library/Application Support/BuildAgentMaintenance` and installs two LaunchAgents:

- `com.sapkalabs.build-agent-maintenance`
- `com.sapkalabs.build-agent-maintenance-watchdog`

LaunchAgents start after the user logs in following a reboot. This matches the existing Azure agent
installation, which also uses LaunchAgents.

To deploy from Windows over the configured SSH alias:

```powershell
.\Install-Remote.ps1 -SshHost inphizs-mac-mini
```

Installation does not run maintenance immediately. Test discovery first with:

```bash
~/Library/Application\ Support/BuildAgentMaintenance/build-agent-maintenance.sh --run-once --dry-run
```

Run maintenance immediately only when interrupting current builds is acceptable:

```bash
~/Library/Application\ Support/BuildAgentMaintenance/build-agent-maintenance.sh --run-once
```

## Uninstall

```bash
/bin/bash scripts/uninstall.sh
```

The uninstaller attempts recovery before unloading the maintenance jobs. It preserves the logs in
Documents and Library/Logs.

## Test

The scripts support macOS Bash 3.2.

```bash
/bin/bash -n scripts/*.sh tests/*.sh
/bin/bash tests/test.sh
```
