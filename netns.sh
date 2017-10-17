#!/bin/bash

# Default and configuration values, can be overridden in netns.conf

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
    local retval="$1"
    shift
    echo -ne '\e[033;31;1m' 1>&2
    echo "$@" 1>&2
    echo -ne '\e[033;0m' 1>&2
    exit "${retval}"
}


# Check if a given network namespace exists.
# netns_exists <name>
function netns_exists() {
    local ns_name="$1"
    # Check if a namespace named $ns_name exists.
    ip netns list | grep --quiet --fixed-string --line-regexp "${ns_name}"
    return $?
}


# Check if a given network interface exists
# is_interface <interface> [<netns>]
function is_interface() {
    local interface="$1"
    local ns_name="$2"
    if [[ -z "${ns_name}" ]]; then
        ip link show "${interface}" &> /dev/null
        return $?
    else
        ip netns exec "${ns_name}" ip link show "${interface}" &> /dev/null
        return $?
    fi
}


# Check if a given network interface is wireless
# is_wireless <interface>
function is_wireless() {
    local interface="$1"
    [[ -e "/sys/class/net/${interface}/phy80211/name" ]]
}


# Return the physical device for the given wireless network interface
# get_phy <interface>
function get_phy() {
    local interface="$1"
    if ! is_wireless "${interface}"; then
        return 1
    else
        cat "/sys/class/net/${interface}/phy80211/name"
    fi
}


# Create a network namespace and do basic setup.
# create_netns <name>
function create_netns() {
    local ns_name="$1"
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


# Add a (physical) interface to a network namespace.
# add_interface <ns_name> <interface> <script>
function add_interface() {
    local ns_name="$1"
    local interface="$2"
    local script="$3"
    # Check the parameters.
    netns_exists "${ns_name}" || \
        { echo_warning "Fatal: Network namespace '${ns_name}' does not exist."; return 8; }
    is_interface "${interface}" || \
        { echo_warning "Fatal: Network interface '${interface}' does not exist."; return 9; }
    # Add the designated interface to the netns.
    if ! is_wireless "${interface}"; then
        # Non-wireless interfaces are moved with ip.
        ip link set dev "${interface}" netns "${ns_name}" || \
            { echo_warning "Fatal: Unable to move interface '${interface}' to network namespace '${ns_name}'."; return 10; }
    else
        # Wireless interfaces need a special kludge.
        # 1. Need to use iw instead of ip.
        # 2. Need to use the physical device instead of the network interface.
        # 3. iw needs the PID of a process inside the target namespace instead of the namespace.
        local phy pid
        phy="$(get_phy "${interface}")"
        # Run sleep inside the network namespace and get its PID.
        ip netns exec "${ns_name}" sleep 5 &
        pid="$!"
        # Actually move the interface.
        iw phy "${phy}" set netns "${pid}" || \
            { echo_warning "Fatal: Unable to move device '${phy}' (${interface}) to network namespace '${ns_name}'."; return 11; }
    fi
    # Store the name of the interface and the script for later.
    id="$(sha224sum <<< "${interface}" | cut -d' ' -f1)"
    echo "interface_${id}:${interface}" >> "${state_file}_${ns_name}"
    if [[ -n "${phy}" ]]; then
        echo "phy_${id}:${phy}" >> "${state_file}_${ns_name}"
    fi
    echo "script_${id}:${script}" >> "${state_file}_${ns_name}"
    # Configure the network.
    if [[ -n "${script}" ]]; then
        export NETNS="${ns_name}"
        ip netns exec "${ns_name}" "${script}" 'up' "${interface}" || \
            { echo_warning "Warning: Unable to configure interface '${interface}' with '${script}'."; return 12; }
    fi
    return 0
}


# Remove an interface from a network namespace
# remove_interface <ns_name> <interface>
function remove_interface() {
    local ns_name="$1"
    local interface="$2"
    local id phy script
    # Check if the namespace exists.
    if ! netns_exists "${ns_name}"; then
        echo_warning "Error: Network namespace '${ns_name}' does not exist."
        return 24
    fi
    id="$(grep -Po "(?<=^interface_)([0-9a-f]*)(?=:${interface}$)" "${state_file}_${ns_name}")"
    phy=$(grep -Po "(?<=^phy_${id}:).*" "${state_file}_${ns_name}")
    script=$(grep -Po "(?<=^script_${id}:).*" "${state_file}_${ns_name}")
    # Check if the interface exists.
    if ! is_interface "${interface}" "${ns_name}"; then
        echo_warning "Error: Interface '${interface}' not found in namespace '${ns_name}'."
        return 25
    fi
    # Bring the interface down using the script.
    if [[ -n "${script}" ]]; then
        export NETNS="${ns_name}"
        ip netns exec "${ns_name}" "${script}" 'down' "${interface}" || \
            echo_warning "Warning: Unable to bring '${interface}' down with ${script}."
    fi
    # Remove the (physical) interface from the netns.
    # This should only be required if some process is still running in the namespace.
    if [[ -n "${interface}" ]]; then
        if [[ -z "${phy}" ]]; then
            ip netns exec "${ns_name}" ip link set dev "${interface}" netns 1 || \
                echo_warning "Warning: Unable to remove '${interface}' from the namespace."
        else
            # Note: 'netns 1' to iw means 'the network namespace where PID 1 lives', not 'network namespace 1'.
            # However, PID 1 should always be in the global network namespace.
            ip netns exec "${ns_name}" iw phy "${phy}" set netns 1 || \
                echo_warning "Warning: Unable to remove device '${phy}' (${interface}) from the namespace."
        fi
    fi
    # Remove the entries from the state file.
    sed -i -e "/_${id}:/d" "${state_file}_${ns_name}" || \
        echo_warning "Warning: Unable to remove '${interface}' from the state file."
    return 0
}


# Delete a network namespace.
# delete_ns <name>
function delete_netns() {
    local ns_name=$1
    local interfaces
    interfaces=($(grep "^interface_[0-9a-f]*:" "${state_file}_${ns_name}" | cut -d: -f2))
    # Check if the namespace exists.
    if ! netns_exists "${ns_name}"; then
        echo_warning "Error: Network namespace '${ns_name}' does not exist."
        return 32
    fi
    for interface in "${interfaces[@]}"; do
        remove_interface "${ns_name}" "${interface}"
    done
    # Remove the namespace-specific resolv.conf file
    rm -f "/etc/netns/${ns_name}/resolv.conf" || \
        echo_warning 'Warning: Unable to remove resolv.conf for the network namespace.'
    # Delete the namespace.
    ip netns delete "${ns_name}" || \
        echo_warning "Warning: Unable to delete namespace '${ns_name}'."
    # Delete the state file.
    rm -f -- "${state_file}_${ns_name}"
}


# Run a command inside a network namespace.
# run <name> <user> <cmd> [<parameters> ...]
function run() {
    local ns_name="$1"
    local user="$2"
    shift
    shift
    local cmd=("$@")
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
    local me
    me=$(basename -- "$0")
cat <<EOH
Usage: ${me} <command> [<parameters>]
 Commands:
  start [-n|--netns <name>] [-s|--script <command>|none] <interface> [<interface> [...]]
      Creates the namespace and moves the interface(s) into the namespace.
      The interface(s) will not be available outside of the namespace.
      Use --script to select a command to bring up and down the interface(s)
      within the namespace. It will be invoked for each interface separately
      with the parameter 'up' or 'down' respectively and the name of the
      interface.
      If script is 'none' the interfaces are left unconfigured.
      If script is not given '${script}' is assumed.
  add [-n|--netns <name>] [-s|--script <command>|none] <interface> [<interface> [...]]
      Adds the given interface(s) to an existing namespace.
      See 'start' for a description of the parameters.
  remove [-n|--netns <name>] <interface> [<interface> [...]]
      Removes the given interface(s) from the namespace and makes them globally
      available again. The interfaces are brought down using the same script
      that was used to bring them up.
  stop [-n|--netns <name>]
      Removes the namespace and frees the interface(s).
  run [-n|--netns <name>] [-u|--user <user>] <command>
      Runs the given command within the namespace.
      If command is not given, '${SHELL}' is assumed.
      The command runs with the privileges of the given user. If the user is
      not specified, it is obtained from the config file (${default_user:-not set}) or from
      pkexec/sudo, (in that order of priority) depending on what is available.
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

# Check if we are in a namespace.
current_namespace="$(ip netns identify)"
if [[ -n "${current_namespace}" ]]; then
    echo_warning "This script should be used from the global namespace only. It currently runs in the namespace '${current_namespace}'."
    echo_warning "Will proceed anyway, but if anything goes haywire, don't come complaining."
fi
unset current_namespace

# Parse the command line parameters.
case "$1" in
    start|add)
        action="$1"
        shift
        ns_name="${default_netns}"
        while [[ "$#" -gt 0 ]]; do
            case "$1" in
                -n|--netns|--netns=*)
                    if [[ "$1" == --netns=* ]]; then
                        ns_name="${1#--netns=}"
                    else
                        ns_name="$2"
                        shift
                    fi
                    ;;
                -s|--script|--script=*)
                    if [[ "$1" == --script=* ]]; then
                        script="${1#--script=}"
                    else
                        script="$2"
                        shift
                    fi
                    if [[ "${script}" == 'none' ]]; then
                        script=''
                    fi
                    ;;
                --)
                    break
                    ;;
                -*)
                    echo_error 1 "Unknown parameter '$1'"
                    ;;
                *)
                    break
                    ;;
            esac
            shift
        done
        if [[ $# -lt 1 ]]; then
            usage
            exit 1
        fi
        interfaces=($@)
        # Check if all interfaces exist before doing anything.
        for interface in "${interfaces[@]}"; do
            if ! is_interface "${interface}"; then
                echo_error 1 "Unknown interface '${interface}'."
            fi
        done
        if [[ "${action}" == 'start' ]]; then
            # Create the namespace.
            create_netns "${ns_name}"
        else
            # Check if the namespace exists but do not create it.
            if ! netns_exists "${ns_name}"; then
                echo_error 1 "Network namespace '${ns_name}' does not exist."
            fi
        fi
        # Add the interfaces.
        for interface in "${interfaces[@]}"; do
            add_interface "${ns_name}" "${interface}" "${script}"
        done
        ;;
    remove)
        shift
        ns_name="${default_netns}"
        while [[ "$#" -gt 0 ]]; do
            case "$1" in
                -n|--netns|--netns=*)
                    if [[ "$1" == --netns=* ]]; then
                        ns_name="${1#--netns=}"
                    else
                        ns_name="$2"
                        shift
                    fi
                    ;;
                --)
                    break
                    ;;
                -*)
                    echo_error 1 "Unknown parameter '$1'"
                    ;;
                *)
                    break
                    ;;
            esac
            shift
        done
        if [[ $# -lt 1 ]]; then
            usage
            exit 1
        fi
        interfaces=($@)
        # Remove the interfaces.
        for interface in "${interfaces[@]}"; do
            remove_interface "${ns_name}" "${interface}"
        done
        ;;
    stop)
        shift
        ns_name="${default_netns}"
        while [[ "$#" -gt 0 ]]; do
            case "$1" in
                -n|--netns|--netns=*)
                    if [[ "$1" == --netns=* ]]; then
                        ns_name="${1#--netns=}"
                    else
                        ns_name="$2"
                        shift
                    fi
                    ;;
                --)
                    break
                    ;;
                -*)
                    echo_error 1 "Unknown parameter '$1'"
                    ;;
                *)
                    break
                    ;;
            esac
            shift
        done
        if [[ $# -gt 1 ]]; then
            usage
            exit 1
        fi
        delete_netns "${ns_name}"
        ;;
    run)
        shift
        [[ -n "${PKEXEC_UID}" ]] && PKEXEC_USER="$(id -un "${PKEXEC_UID}")"
        user="${default_user:-${PKEXEC_USER:-${SUDO_USER:-${USER}}}}"
        ns_name="${default_netns}"
        while [[ "$#" -gt 0 ]]; do
            case "$1" in
                -n|--netns|--netns=*)
                    if [[ "$1" == --netns=* ]]; then
                        ns_name="${1#--netns=}"
                    else
                        ns_name="$2"
                        shift
                    fi
                    ;;
                -u|--user|--user=*)
                    if [[ "$1" == --user=* ]]; then
                        user="${1#--user=}"
                    else
                        user="$2"
                        shift
                    fi
                    ;;
                --)
                    break
                    ;;
                -*)
                    echo_error 1 "Unknown parameter '$1'"
                    ;;
                *)
                    break
                    ;;
            esac
            shift
        done
        cmd=("$@")
        [[ -z "${cmd[@]}" ]] && cmd=("${SHELL}")
        run "${ns_name}" "${user}" "${cmd[@]}"
        ;;
    *)
        usage
        exit 1
        ;;
esac
