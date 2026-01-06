#!/bin/bash
# Library for disk inventory functions

# Get cluster nodes from Proxmox cluster configuration
get_cluster_nodes() {
    local nodes=()
    
    # Check if running on a Proxmox cluster node
    if [ -f /etc/pve/corosync.conf ]; then
        # Parse corosync.conf for node names/IPs
        nodes=($(grep -A 10 "nodelist {" /etc/pve/corosync.conf | grep "name:" | awk '{print $2}' | sort -u))
    fi
    
    # If no cluster configuration found, use localhost
    if [ ${#nodes[@]} -eq 0 ]; then
        nodes=("localhost")
    fi
    
    echo "${nodes[@]}"
}

# Get disk information from a node
get_disk_info() {
    local node=$1
    local ssh_prefix=""
    
    # Set up SSH prefix if not localhost
    if [ "$node" != "localhost" ] && [ "$node" != "$(hostname)" ]; then
        ssh_prefix="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${node}"
    fi
    
    # Get all block devices
    if [ -n "$ssh_prefix" ]; then
        $ssh_prefix "lsblk -d -o NAME,TYPE,SIZE,MODEL,SERIAL -n | grep -E 'disk'"
    else
        lsblk -d -o NAME,TYPE,SIZE,MODEL,SERIAL -n | grep -E 'disk'
    fi
}

# Detect disk type (NVMe, SSD, HDD)
detect_disk_type() {
    local disk=$1
    local node=$2
    local ssh_prefix=""
    
    # Set up SSH prefix if not localhost
    if [ "$node" != "localhost" ] && [ "$node" != "$(hostname)" ]; then
        ssh_prefix="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${node}"
    fi
    
    # Check if NVMe
    if [[ $disk == nvme* ]]; then
        echo "NVMe"
        return
    fi
    
    # Check if SSD or HDD based on rotational flag
    local rotational
    if [ -n "$ssh_prefix" ]; then
        rotational=$($ssh_prefix "cat /sys/block/${disk}/queue/rotational 2>/dev/null || echo '1'")
    else
        rotational=$(cat /sys/block/${disk}/queue/rotational 2>/dev/null || echo '1')
    fi
    
    if [ "$rotational" = "0" ]; then
        echo "SSD"
    else
        echo "HDD"
    fi
}

# Get detailed disk information including smartctl if available
get_detailed_disk_info() {
    local disk=$1
    local node=$2
    local ssh_prefix=""
    
    # Set up SSH prefix if not localhost
    if [ "$node" != "localhost" ] && [ "$node" != "$(hostname)" ]; then
        ssh_prefix="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${node}"
    fi
    
    # Try to get more detailed info from smartctl
    local model=""
    local serial=""
    local size=""
    
    if [ -n "$ssh_prefix" ]; then
        if $ssh_prefix "command -v smartctl &>/dev/null"; then
            local smart_info=$($ssh_prefix "smartctl -i /dev/${disk} 2>/dev/null")
            model=$(echo "$smart_info" | grep -i "Device Model:\|Model Number:\|Model Family:" | head -1 | sed 's/.*: *//')
            serial=$(echo "$smart_info" | grep -i "Serial Number:" | head -1 | sed 's/.*: *//')
        fi
        size=$($ssh_prefix "lsblk -d -o SIZE -n /dev/${disk} 2>/dev/null")
    else
        if command -v smartctl &>/dev/null; then
            local smart_info=$(smartctl -i /dev/${disk} 2>/dev/null)
            model=$(echo "$smart_info" | grep -i "Device Model:\|Model Number:\|Model Family:" | head -1 | sed 's/.*: *//')
            serial=$(echo "$smart_info" | grep -i "Serial Number:" | head -1 | sed 's/.*: *//')
        fi
        size=$(lsblk -d -o SIZE -n /dev/${disk} 2>/dev/null)
    fi
    
    # Fallback to lsblk if smartctl didn't provide info
    if [ -z "$model" ] || [ -z "$serial" ]; then
        if [ -n "$ssh_prefix" ]; then
            local lsblk_info=$($ssh_prefix "lsblk -d -o MODEL,SERIAL /dev/${disk} -n 2>/dev/null")
        else
            local lsblk_info=$(lsblk -d -o MODEL,SERIAL /dev/${disk} -n 2>/dev/null)
        fi
        [ -z "$model" ] && model=$(echo "$lsblk_info" | awk '{print $1}')
        [ -z "$serial" ] && serial=$(echo "$lsblk_info" | awk '{print $2}')
    fi
    
    # Clean up empty values
    [ -z "$model" ] && model="N/A"
    [ -z "$serial" ] && serial="N/A"
    [ -z "$size" ] && size="N/A"
    
    echo "$size|$model|$serial"
}

# Check if node is reachable
check_node_reachable() {
    local node=$1
    
    if [ "$node" = "localhost" ] || [ "$node" = "$(hostname)" ]; then
        return 0
    fi
    
    # Try to ping the node
    ping -c 1 -W 2 "$node" &>/dev/null
    return $?
}
