#!/bin/bash

# This is a simple wrapper around dhclient

action="$1"
interface="$2"

if [[ "${action}" == 'up' ]]; then
    # Bring the interface up with dhcp
    dhclient -pf "/run/dhclient_${interface}.pid" -e NETNS="$NETNS" "${interface}"
else
    # Stop dhclient
    dhclient -pf "/run/dhclient_${interface}.pid" -e NETNS="$NETNS" -r
fi
