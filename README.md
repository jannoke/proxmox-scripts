# proxmox-scripts

A collection of useful scripts for Proxmox VE administration and management.

## Scripts

### Disk Inventory Script

**Location:** `bin/disk-inventory.sh`

A comprehensive disk inventory tool for Proxmox VE clusters that scans all nodes and collects information about installed disks.

#### Features

- **Multi-node support**: Automatically detects all nodes in a Proxmox cluster
- **Disk type detection**: Identifies NVMe, SSD, and HDD drives
- **Comprehensive information**: Collects device names, models, serial numbers, and sizes
- **SSH integration**: Executes commands across cluster nodes via SSH
- **Human-readable output**: Color-coded, formatted table display

#### Requirements

- Proxmox VE 9.x
- SSH access configured between cluster nodes (typically already configured in Proxmox)
- Root privileges (or sudo)
- Optional: `smartmontools` package for enhanced disk information

**Security Note:** The script uses `StrictHostKeyChecking=accept-new` for SSH connections, which accepts new host keys but verifies known ones. In a Proxmox cluster, SSH keys are typically pre-configured and trusted. If you need stricter security policies, modify the `SSH_OPTS` variable in `includes/disk_inventory_lib.sh`.

#### Installation

```bash
# Clone the repository
git clone https://github.com/jannoke/proxmox-scripts.git
cd proxmox-scripts

# Make the script executable (if not already)
chmod +x bin/disk-inventory.sh
```

#### Usage

Run the script on any Proxmox cluster node:

```bash
# Run from the repository root
./bin/disk-inventory.sh

# Or run from anywhere (using full path)
/path/to/proxmox-scripts/bin/disk-inventory.sh
```

#### Output Example

```
═══════════════════════════════════════════════════════════════════════════
                    PROXMOX CLUSTER DISK INVENTORY
═══════════════════════════════════════════════════════════════════════════

Scan Date: 2026-01-06 13:17:00

Detecting cluster nodes...
Found 3 node(s): pve1 pve2 pve3

───────────────────────────────────────────────────────────────────────────
Node: pve1
───────────────────────────────────────────────────────────────────────────
  ✓ Node is reachable

  DEVICE           TYPE    SIZE        MODEL                           SERIAL NUMBER       
  ───────────────  ──────  ──────────  ──────────────────────────────  ────────────────────
  nvme0n1          NVMe    1TB         Samsung SSD 980 PRO             S5GXNX0T123456      
  sda              SSD     500GB       Samsung SSD 860 EVO             S3Z9NX0M789012      
  sdb              HDD     2TB         WDC WD20EZRZ                    WD-WCC4M1234567     

  Total disks on this node: 3

───────────────────────────────────────────────────────────────────────────
Summary
───────────────────────────────────────────────────────────────────────────
  Total Nodes Scanned: 3
  Total Disks Found:   9

  Disk Type Breakdown:
    NVMe: 3
    SSD:  3
    HDD:  3

═══════════════════════════════════════════════════════════════════════════
```

#### How It Works

1. **Cluster Detection**: The script reads `/etc/pve/corosync.conf` to identify all nodes in the cluster
2. **Node Connection**: For each node, it establishes an SSH connection (or uses local commands for the current node)
3. **Disk Discovery**: Uses `lsblk` to find all physical disk devices
4. **Type Classification**: Determines disk type (NVMe/SSD/HDD) based on device name and rotational flag
5. **Information Gathering**: Collects detailed information using `smartctl` (if available) or `lsblk`
6. **Output Formatting**: Presents all collected data in a human-readable, color-coded table

#### Troubleshooting

**Node not reachable**
- Ensure SSH is properly configured between cluster nodes
- Check network connectivity with `ping <node-name>`
- Verify SSH keys are set up for passwordless authentication

**Missing disk information**
- Install `smartmontools` for more detailed disk information:
  ```bash
  apt-get install smartmontools
  ```

**Permission denied**
- Run the script with root privileges:
  ```bash
  sudo ./bin/disk-inventory.sh
  ```

## Directory Structure

```
proxmox-scripts/
├── bin/                    # Executable scripts
│   └── disk-inventory.sh   # Main disk inventory script
├── includes/               # Shared libraries and functions
│   └── disk_inventory_lib.sh
├── LICENSE
└── README.md
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

See LICENSE file for details.