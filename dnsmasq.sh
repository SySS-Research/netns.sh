#!/bin/bash

# This will supply clients on the interface with DHCP using dnsmasq.
# No routing, NATing or other fancy stuff is provided by this script.
# The DHCP address range is hard-coded for simplicity but can be changed if needed.

# Path where all dnsmasq-related temporary files are stored.
file_path="/tmp/${NETNS}"
# Name of the config file.
conf_file="dnsmasq.conf"
# Name of the log file.
log_file="dnsmasq.log"
# Name of the pid file.
pid_file="dnsmasq.pid"

action="$1"
interface="$2"

if [[ "${action}" == 'up' ]]; then

    mkdir -p -- "${file_path}"
    touch -- "${file_path}/${log_file}"
    cat > "${file_path}/${conf_file}" <<EOF
# DNS MitM sample
# address=/syss.de/192.168.0.1
no-resolv
interface="${interface}"
dhcp-range=192.168.0.100,192.168.0.254,12h
dhcp-option=3,192.168.0.1 # Router (Gateway)
dhcp-option=6,192.168.0.1 # DNS Server
log-facility="${file_path}/${log_file}"
log-queries
EOF
    ip addr add 192.168.0.1/24 dev "${interface}"
    ip route add 224.0.0.0/4 dev "${interface}"
    ip link set dev "${interface}" up
    dnsmasq -x "${file_path}/${pid_file}" -C "${file_path}/${conf_file}"

else

    kill "$(cat "${file_path}/${pid_file}")"
    rm -rf -- "${file_path}"

fi
