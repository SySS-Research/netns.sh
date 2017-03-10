#!/bin/bash

# Default and configuratio values, can be overridden in netns.conf

# Name of the default network namespace that is used when no name is given.
default_netns="default"

# Name of the file where settings are stored temporarily.
# The file is suffixed with the name of the network namespace that is used.
state_file="/run/netns"

# Default script to bring up and down the interface within the namespace.
script="$(dirname -- "$(realpath -- "$0")")/dhclient.sh"

# Default user to run commands as within the namespace
#default_user='pentest'

# Read the values from netns.conf
config_file="$(dirname -- "$(realpath -- "$0")")/netns.conf"
if [[ -r "${config_file}" ]]; then
    # shellcheck disable=SC1090
    source "${config_file}"
fi


# Print a warning message to stderr.
# echo_warning <msg> ...
function echo_warning() {
    echo -ne '\e[033;33;1m' 1>&2
    echo "$@" 1>&2
    echo -ne '\e[033;0m' 1>&2
}

# Print an error message to stderr and exit with the given exit code.
# echo_error <exit_code> <msg> ...
function echo_error() {
    retval="$1"
    shift
    echo -ne '\e[033;31;1m' 1>&2
    echo "$@" 1>&2
    echo -ne '\e[033;0m' 1>&2
    exit "${retval}"
}


# Check if a given network namespace exists.
# netns_exists <name>
function netns_exists() {
    ns_name="$1"
    # Check if a namespace named $ns_name exists.
    # Note: This can not be done with grep, as $ns_name may contain
    # metacharacters and using --fixed-string does not allow anchoring
    # the pattern.
    ip netns list | grep --quiet --fixed-string --line-regexp "${ns_name}"
    return $?
}


# Create a network namespace and do basic setup.
# create_netns <name>
function create_netns() {
    ns_name="$1"
    netns_exists "${ns_name}" && return 0
    # Create the namespace.
    ip netns add "${ns_name}" || \
        echo_error 2 'Fatal: Unable to create network namespace.'
    # Setup separated DNS support.
    mkdir -p "/etc/netns/${ns_name}/" || \
        echo_error 3 'Fatal: Unable to setup resolv.conf for the network namespace.'
    if [[ -e "/etc/netns/${ns_name}/resolv.conf" ]]; then
        rm -- "/etc/netns/${ns_name}/resolv.conf" || \
            echo_error 4 'Fatal: Unable to remove old resolv.conf for the network namespace.'
    fi
    (set -o noclobber; > "/etc/netns/${ns_name}/resolv.conf") || \
        echo_error 5 'Fatal: Unable to setup resolv.conf for the network namespace.'
    # Bring up the lo interface inside the namespace.
    ip netns exec "${ns_name}" ip link set dev lo up || \
        echo_warning 'Error: Unable to setup the lo interface.'
    # Create the state file.
    if [[ -e "${state_file}_${ns_name}" ]]; then
        rm -- "${state_file}_${ns_name}"
    fi
    (set -o noclobber; > "${state_file}_${ns_name}")
    return 0
}


# Connect a network namespace via a (physical) interface.
# connect_netns <name> <interface>
function connect_netns() {
    ns_name="$1"
    interface="$2"
    script="$3"
    # Check the parameters.
    netns_exists "${ns_name}" || \
        echo_error 8 "Fatal: Network namespace '${ns_name}' does not exist."
    ip link show "${interface}" > /dev/null || \
        echo_error 9 "Fatal: Network interface '${interface}' does not exist."
    # Add the designated interface to the netns.
    ip link set dev "${interface}" netns "${ns_name}" || \
        echo_error 10 "Fatal: Unable to move interface '${interface}' to network namespace."
    # Store the name of the interface and the script for later.
    echo "interface:${interface}" >> "${state_file}_${ns_name}"
    echo "script:${script}" >> "${state_file}_${ns_name}"
    # Configure the network.
    ip netns exec "${ns_name}" "${script}" 'up' "${interface}" || \
        echo_error 11 "Fatal: Unable to configure network with '${script}'."
    return 0
}


# Delete a network namespace.
# delete_ns <name>
function delete_netns() {
    ns_name=$1
    interface=$(grep "^interface:" "${state_file}_${ns_name}" | cut -d: -f2)
    script=$(grep "^script:" "${state_file}_${ns_name}" | cut -d: -f2)
    # Check if the namespace exists.
    if ! netns_exists "${ns_name}"; then
        return
    fi
    ip netns exec "${ns_name}" "${script}" 'down' "${interface}" || \
        echo_warning "Warning: Unable to bring '${interface}' down with ${script}."
    # Remove the (physical) interface from the netns.
    # This should only be required if some process is still running in the namespace.
    ip netns exec "${ns_name}" ip link set dev "${interface}" netns 1 || \
        echo_warning "Warning: Unable to remove '${interface}' from the namespace."
    # Remove the namespace-specific resolv.conf file
    rm -f "/etc/netns/${ns_name}/resolv.conf" || \
        echo_warning 'Warning: Unable to remove resolv.conf for the network namespace.'
    # Delete the namespace.
    ip netns delete "${ns_name}" || \
        echo_warning "Warning: Unable to delete namespace '${ns_name}'."
}


# Run a command inside a network namespace.
# run <name> <user> <cmd> [<parameters> ...]
function run() {
    ns_name="$1"
    user="$2"
    shift
    shift
    cmd=($@)
    if ! netns_exists "${ns_name}"; then
        echo_error 16 "Fatal: Namespace '${ns_name}' does not exist."
    fi
    if [[ -n "${user}" ]]; then
        # Run $cmd inside the namespace, using sudo to drop privileges to the
        # invoking user.
        # Try to export the name of the network namespace in NETNS.
        # sudo may or may not allow this.
        export NETNS="${ns_name}"
        ip netns exec "${ns_name}" sudo -u "${user}" "${cmd[@]}"
        r="$?"
    else
        # Run $cmd inside the namespace, but do not drop privileges.
        NETNS="${ns_name}" ip netns exec "${ns_name}" "${cmd[@]}"
        r="$?"
    fi
    [[ $r -gt 0 ]] && echo_warning "Warning: Running '${cmd[*]}' failed."
    return "$r"
}


# Display a short help message.
function usage() {
    me=$(basename -- "$0")
cat <<EOH
Usage: ${me} <command> [<parameters>]
 Commands:
  start [-s|--script <command>] [<name>] <interface>
      Creates the namespace and moves the interface into the namespace.
      The interface will not be available outside of the namespace.
      Use --script to select a command to bring up and down the interface
      within the namespace. It will be invoked with the parameter 'up' or
      'down' respectively and the name of the interface.
      If script is not given '${script}' is assumed.
  stop [<name>]
      Removes the namespace and frees the interface.
  run [-u|--user <user>] [<name>] <command>
      Runs the given command within the namespace.
      If command is not given, '${SHELL}' is assumed.
      The command runs with the privileges of the given user. If the user is
      not specified, '${default_user:-${SUDO_USER:-${USER}}}' is assumed.
 The name of the network namespace to use is optional for all commands.
 If it is not given, the default value '${default_netns}' is assumed.
 Note: ${me} requires root privileges. It uses sudo to automatically drop
       privileges before running commands within the namespace.
EOH
}


# Check for root privileges.
if [[ $UID -gt 0 ]]; then
    echo_warning 'Error: This script requires root privileges.'
    usage
    exit 1
fi

# Parse the command line parameters.
case "$1" in
    start)
        shift
        if [[ "$1" == '-s' ]] || [[ "$1" == '--script' ]]; then
            script="$2"
            shift
            shift
        fi
        if [[ $# -lt 1 || $# -gt 2 ]]; then
            usage
            exit 1
        fi
        if [[ $# == 2 ]]; then
            ns_name="$1"
            shift
        else
            ns_name="${default_netns}"
        fi
        interface="$1"
        create_netns "${ns_name}"
        connect_netns "${ns_name}" "${interface}" "${script}"
        ;;
    stop)
        shift
        if [[ $# -gt 1 ]]; then
            usage
            exit 1
        fi
        if [[ $# == 1 ]]; then
            ns_name=$1
            shift
        else
            ns_name="${default_netns}"
        fi
        delete_netns "${ns_name}"
        ;;
    run)
        shift
        user="${default_user:-${SUDO_USER:-${USER}}}"
        if [[ "$1" == '-u' ]] || [[ "$1" == '--user' ]]; then
            user="$2"
            shift
            shift
        fi
        if [[ -n "$1" ]] && netns_exists "$1"; then
            ns_name="$1"
            shift
        else
            ns_name="${default_netns}"
        fi
        cmd=($@)
        [[ -z "${cmd[@]}" ]] && cmd=("${SHELL}")
        run "${ns_name}" "${user}" "${cmd[@]}"
        ;;
    *)
        usage
        exit 1
        ;;
esac
