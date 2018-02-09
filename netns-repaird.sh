#!/bin/bash

# Simple deamon to automatically repair DNS settings in network namespaces whenever NetworkManager (or something) breaks them.
# Idea: Watch /etc/resolv.conf outside the network namespace and whenever it changes, re-create the mount in all current mount namespaces.
# Breaking the mount does not generate an inotify event inside the namespace, so the watch needs to be set on the outside file.

pid_file='/run/netns-repaird.pid'


function wait_and_repair() {
    # Make sure to clean up the PID file and the child processes when this script exits.
    trap 'rm -f -- ${pid_file}; kill 0' EXIT
    trap exit INT TERM

    # Write PID file.
    pid=$BASHPID
    (set -o noclobber; echo ${pid} > "${pid_file}")
    # shellcheck disable=SC2181
    if [[ $? -gt 0 ]]; then
        # PID file could not be written
        echo "Warning: Could not write PID file '${pid_file}'." >&2
    fi

    if ${quiet}; then
        inotifywait_quiet="-qq"
    fi

    # This is the main loop. inotifywait will stop watching if the watched file is removed.
    # As this is the only event of interest here, it is run in a loop to set up a new watch on the new file.
    # Note: Bash won't receive signals while inotifywait is in the foreground, hence we start it in the background and wait for it to finish.
    while { inotifywait "${inotifywait_quiet}" -e delete_self -e move_self /etc/resolv.conf & wait $!; } do
        for namespace in $(ip netns); do
            if [[ -f "/etc/netns/${namespace}/resolv.conf" ]]; then
                # Note: ip netns exec creates a new mount namespace on each invocation and sets everything up correctly.
                # Therefore, we can not use ip netns exec to fix issues for processes that are already running.
                # Instead, enter the mount namespaces directly and fix each of them (if needed).
                # It would suffice to do it for one process from each mount namespace, but getting and comparing that information is more complex than checking the namespaces over and over again...
                for pid in $(ip netns pids "${namespace}"); do
                    nsenter -m -t "${pid}" sh -c "grep -Fwq '/etc/resolv.conf' /proc/mounts || { ${quiet} || echo Repairing process ${pid} in namespace ${namespace}...; mount --bind '/etc/netns/${namespace}/resolv.conf' /etc/resolv.conf; }"
                done
            fi
        done
    done
}


# Process the command line parameters.
quiet=false
foreground=false
killold=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            cat <<EOH
Usage: $(basename -- "$0") [-h|--help] [-q|--quiet]
  This is a simple daemon that automatically repairs DNS settings in network
  namespaces whenever NetworkManager or something else breaks them. It can be
  run manually, but this should not be neccessary as it is automatically
  handled by netns.sh.
  Note: This daemon requires root privileges.
  Options:
    -h, --help        Show this help and exit
    -q, --quiet       Reduce console output to errors only
    -f, --foreground  Do not fork to a background process
    -k, --kill        Kill an already running instance of this daemon
EOH
            shift
            ;;
        -q|--quiet)
            quiet=true
            shift
            ;;
        -f|--foreground)
            foreground=true
            shift
            ;;
        -k|--kill)
            killold=true
            shift
            ;;
        *)
            echo "Unknown parameter '$1'." >&2
            exit 2
            ;;
    esac
done

# Check dependencies.
for prog in inotifywait ip nsenter ps; do
    if ! command -v "${prog}" >/dev/null; then
        echo "Error: Missing dependency '${prog}'."
        exit 4
    fi
done

# Check for root privileges.
if [[ $UID -gt 0 ]]; then
    echo 'Error: This script requires root privileges.' >&2
    exit 3
fi

if ${killold}; then
    # Kill an existing instance of this script.
    if [[ -e "${pid_file}" ]]; then
        pid="$(cat "${pid_file}")"
        if ps -p "${pid}" &>/dev/null; then
            kill "${pid}" && exit 0
        fi
        unset pid
    fi
    # At this point, kill failed or was not attempted at all.
    if ! ${quiet}; then
        echo 'Error: Could not find old instance to kill.' >&2
    fi
    exit 8
else
    # Check for another instance.
    if [[ -e "${pid_file}" ]]; then
        pid="$(cat "${pid_file}")"
        if ps -p "${pid}" &>/dev/null; then
            # There is already an instance of this script running, no need to run another.
            if ! ${quiet}; then
                echo "It seems that there is already an instance of $(basename -- "$0") running. If you are sure there is none, please remove '${pid_file}' and try again." >&2
            fi
            exit 1
        fi
        unset pid
    fi

    # Start doing actual work.
    if ${foreground}; then
        wait_and_repair
    else
        wait_and_repair &
    fi
fi
