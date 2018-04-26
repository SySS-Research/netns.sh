#!/bin/bash

# This is a simple wrapper around udhcpc (part of busybox)

action="$1"
interface="$2"

if [[ "${action}" == 'up' ]]; then
    # Bring the interface up with dhcp
    busybox udhcpc -s "$(dirname -- "$0")/../misc/udhcpc.script" -p "/run/udhcpc_${interface}.pid" -R -i "${interface}"
else
    # Stop udhcpc
    if [[ -f "/run/udhcpc_${interface}.pid" ]]; then
        pid="$(cat "/run/udhcpc_${interface}.pid")"
        if [[ -n "${pid}" ]]; then
            kill -- "${pid}"
            rm -- "/run/udhcpc_${interface}.pid"
        else
            echo 'Error: PID file for udhcpc is empty. Can not terminate it.' >&2
            exit 2
        fi
    else
        echo 'Error: PID file for udhcpc is missing. Can not terminate it.' >&2
        exit 1
    fi
fi
