#!/bin/bash
#
# Proxmox Disk Inventory Script
# 
# This script inventories all disks (NVMe, SSD, HDD) across a Proxmox cluster
# and displays their names, models, and serial numbers.
#
# Usage: ./disk-inventory.sh
#

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INCLUDES_DIR="$(dirname "$SCRIPT_DIR")/includes"

# Source the library functions
if [ -f "$INCLUDES_DIR/disk_inventory_lib.sh" ]; then
    source "$INCLUDES_DIR/disk_inventory_lib.sh"
else
    echo "Error: Could not find disk_inventory_lib.sh in $INCLUDES_DIR"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print header
print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "                    PROXMOX CLUSTER DISK INVENTORY"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Scan Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

# Print section header
print_section() {
    local title=$1
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo -e "${CYAN}${title}${NC}"
    echo "───────────────────────────────────────────────────────────────────────────"
}

# Print disk entry
print_disk() {
    local node=$1
    local disk=$2
    local type=$3
    local size=$4
    local model=$5
    local serial=$6
    
    local type_color=""
    case $type in
        "NVMe")
            type_color="${GREEN}"
            ;;
        "SSD")
            type_color="${BLUE}"
            ;;
        "HDD")
            type_color="${YELLOW}"
            ;;
    esac
    
    printf "  %-15s  ${type_color}%-6s${NC}  %-10s  %-30s  %-20s\n" \
        "$disk" "$type" "$size" "$model" "$serial"
}

# Main execution
main() {
    print_header
    
    # Get cluster nodes
    echo -e "${CYAN}Detecting cluster nodes...${NC}"
    local nodes=()
    mapfile -t nodes < <(get_cluster_nodes | tr ' ' '\n')
    echo "Found ${#nodes[@]} node(s): ${nodes[*]}"
    echo ""
    
    # Counter for total disks
    local total_disks=0
    local total_nvme=0
    local total_ssd=0
    local total_hdd=0
    
    # Iterate through each node
    for node in "${nodes[@]}"; do
        print_section "Node: $node"
        
        # Check if node is reachable
        if ! check_node_reachable "$node"; then
            echo -e "${RED}  ✗ Node is not reachable${NC}"
            continue
        fi
        
        echo -e "${GREEN}  ✓ Node is reachable${NC}"
        echo ""
        
        # Print table header
        printf "  %-15s  %-6s  %-10s  %-30s  %-20s\n" \
            "DEVICE" "TYPE" "SIZE" "MODEL" "SERIAL NUMBER"
        printf "  %-15s  %-6s  %-10s  %-30s  %-20s\n" \
            "───────────────" "──────" "──────────" "──────────────────────────────" "────────────────────"
        
        # Get list of disk devices
        local disks=()
        local ssh_cmd=()
        if [ "$node" != "localhost" ] && [ "$node" != "$(hostname)" ]; then
            ssh_cmd=(ssh "${SSH_OPTS[@]}" "root@${node}")
        fi
        
        if [ ${#ssh_cmd[@]} -gt 0 ]; then
            mapfile -t disks < <("${ssh_cmd[@]}" "lsblk -d -o NAME -n | grep -E '${DISK_PATTERN}'")
        else
            mapfile -t disks < <(lsblk -d -o NAME -n | grep -E "${DISK_PATTERN}")
        fi
        
        # Process each disk
        local node_disk_count=0
        for disk in "${disks[@]}"; do
            # Detect disk type
            local disk_type=$(detect_disk_type "$disk" "$node")
            
            # Get detailed information
            local disk_details=$(get_detailed_disk_info "$disk" "$node")
            local size=$(echo "$disk_details" | cut -d'|' -f1)
            local model=$(echo "$disk_details" | cut -d'|' -f2)
            local serial=$(echo "$disk_details" | cut -d'|' -f3)
            
            # Print disk information
            print_disk "$node" "$disk" "$disk_type" "$size" "$model" "$serial"
            
            # Update counters
            ((node_disk_count++))
            ((total_disks++))
            
            case $disk_type in
                "NVMe") ((total_nvme++)) ;;
                "SSD") ((total_ssd++)) ;;
                "HDD") ((total_hdd++)) ;;
            esac
        done
        
        if [ $node_disk_count -eq 0 ]; then
            echo "  No disks found on this node."
        else
            echo ""
            echo "  Total disks on this node: $node_disk_count"
        fi
    done
    
    # Print summary
    print_section "Summary"
    echo "  Total Nodes Scanned: ${#nodes[@]}"
    echo "  Total Disks Found:   $total_disks"
    echo ""
    echo "  Disk Type Breakdown:"
    echo -e "    ${GREEN}NVMe:${NC} $total_nvme"
    echo -e "    ${BLUE}SSD:${NC}  $total_ssd"
    echo -e "    ${YELLOW}HDD:${NC}  $total_hdd"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
}

# Run main function
main
