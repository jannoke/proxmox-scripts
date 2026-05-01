#!/bin/bash

NODES="node1 node2 node3"

for node in $NODES; do
    gov=$(ssh "$node" 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null')

    if [ -z "$gov" ]; then
        echo "$node: ERROR / no cpufreq governor found"
    else
        echo "$node: $gov"
    fi
done
