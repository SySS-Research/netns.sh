#!/bin/bash

# This is a simple wrapper around dhcpcd

action="$1"
interface="$2"

if [[ "${action}" == 'up' ]]; then
    # Bring the interface up with dhcp
    dhcpcd -e NETNS="$NETNS" "${interface}"
else
    # Stop dhclient
    dhcpcd -x "${interface}"
fi
