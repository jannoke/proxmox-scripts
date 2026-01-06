#!/bin/bash
# Library for disk inventory functions

# SSH options for cluster communication
# In Proxmox clusters, nodes are typically pre-configured with trusted SSH keys
# If you need stricter security, modify these options or use SSH config
declare -a SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)

# Get cluster nodes from Proxmox cluster configuration
get_cluster_nodes() {
    local nodes=()
    
    # Check if running on a Proxmox cluster node
    if [ -f /etc/pve/corosync.conf ]; then
        # Parse corosync.conf for node names/IPs
        # Use awk to properly parse the nodelist section, handling various whitespace
        mapfile -t nodes < <(awk '/nodelist/,/^[[:space:]]*\}/ {
            if ($0 ~ /name:/) {
                # Extract the value after "name:", handling various formats
                gsub(/^[[:space:]]*name:[[:space:]]*/, "");
                gsub(/[[:space:]]*$/, "");
                print $0;
            }
        }' /etc/pve/corosync.conf | sort -u)
    fi
    
    # If no cluster configuration found, use localhost
    if [ ${#nodes[@]} -eq 0 ]; then
        nodes=("localhost")
    fi
    
    echo "${nodes[@]}"
}

# Detect disk type (NVMe, SSD, HDD)
detect_disk_type() {
    local disk=$1
    local node=$2
    local ssh_cmd=()
    
    # Set up SSH command array if not localhost
    if [ "$node" != "localhost" ] && [ "$node" != "$(hostname)" ]; then
        ssh_cmd=(ssh "${SSH_OPTS[@]}" "root@${node}")
    fi
    
    # Check if NVMe (nvme devices include the namespace, e.g., nvme0n1, nvme1n1)
    if [[ $disk =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        echo "NVMe"
        return
    fi
    
    # Check if SSD or HDD based on rotational flag
    local rotational
    if [ ${#ssh_cmd[@]} -gt 0 ]; then
        rotational=$("${ssh_cmd[@]}" "cat /sys/block/${disk}/queue/rotational 2>/dev/null || echo '1'")
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
    local ssh_cmd=()
    
    # Set up SSH command array if not localhost
    if [ "$node" != "localhost" ] && [ "$node" != "$(hostname)" ]; then
        ssh_cmd=(ssh "${SSH_OPTS[@]}" "root@${node}")
    fi
    
    # Try to get more detailed info from smartctl
    local model=""
    local serial=""
    local size=""
    
    if [ ${#ssh_cmd[@]} -gt 0 ]; then
        if "${ssh_cmd[@]}" "command -v smartctl &>/dev/null"; then
            local smart_info=$("${ssh_cmd[@]}" "smartctl -i /dev/${disk} 2>/dev/null")
            model=$(echo "$smart_info" | grep -i "Device Model:\|Model Number:\|Model Family:" | head -1 | sed 's/.*: *//')
            serial=$(echo "$smart_info" | grep -i "Serial Number:" | head -1 | sed 's/.*: *//')
        fi
        size=$("${ssh_cmd[@]}" "lsblk -d -o SIZE -n /dev/${disk} 2>/dev/null")
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
        if [ ${#ssh_cmd[@]} -gt 0 ]; then
            local lsblk_info=$("${ssh_cmd[@]}" "lsblk -d -o MODEL,SERIAL /dev/${disk} -n 2>/dev/null")
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
