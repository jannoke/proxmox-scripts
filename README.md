# proxmox-scripts

A collection of useful scripts for Proxmox VE administration and management.

## Scripts

### Cluster CPU Performance Governor Script

**Location:** `bin/clusterPerformance.sh`

Manages CPU power governor settings (`performance`, `powersave`, etc.) across all Proxmox cluster nodes. Supports get, set, backup/restore, JSON output, logging, and CPU temperature reporting.

> Full documentation including examples, JSON output format, and backup file format is in the [Cluster CPU Performance Governor Script](#cluster-cpu-performance-governor-script-1) section below.

---

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

1. **Cluster Detection**: The script uses `pvecm nodes` command to dynamically identify all nodes in the cluster
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

### Cluster CPU Performance Governor Script

**Location:** `bin/clusterPerformance.sh`

A comprehensive tool for managing CPU power governor settings across all nodes in a Proxmox VE cluster.

#### Features

- **Node auto-detection**: Reads `/etc/pve/corosync.conf` or `/etc/pve/.members`; falls back to `pvecm nodes` or `localhost`
- **Get current governors**: Displays per-node CPU governor status, detecting mixed-governor nodes
- **List available governors**: Shows which governors are supported on each node
- **Set governors**: Change governor on one, several, or all nodes with optional pre-change backup and post-change verification
- **Backup / Restore**: Save and restore per-CPU governor state to `/etc/pve/.clusterPerformance.backup`
- **JSON output**: Machine-readable JSON for scripting and monitoring pipelines
- **Temperature monitoring**: Reads `/sys/class/thermal/thermal_zone*/temp` and reports average / max CPU temperature per node
- **Structured logging**: Timestamped log lines at INFO / SUCCESS / WARNING / ERROR levels; supports log file and syslog (daemon facility)
- **Quiet mode**: `-q/--quiet` suppresses stdout for cron usage
- **Configurable SSH timeout**: `--timeout <seconds>` (default: 10 s)

#### Requirements

- Proxmox VE 9.x
- SSH access configured between cluster nodes (typically pre-configured in Proxmox)
- Root privileges (or sudo)
- `cpufreq` kernel support on each node

#### Installation

```bash
chmod +x bin/clusterPerformance.sh
```

#### Usage

```
clusterPerformance.sh [COMMAND] [ARGUMENTS] [OPTIONS]

Commands:
  get                   Get current CPU governors (default)
  list-available        List available governors per node
  set <governor>        Set governor on nodes
  backup                Save current governor state to file
  restore               Restore previously saved state

Node Selection:
  --nodes node1,node2   Comma-separated list of nodes
  --all                 All cluster nodes (default)

Output Options:
  --json                Output in JSON format
  --show-temp           Show CPU temperatures alongside governor info
  -q, --quiet           Minimal output (for cron jobs)

Logging Options:
  --log-file <file>     Log operations to file
  --syslog              Log to syslog (daemon facility)

Other Options:
  --backup              Backup before setting (used with 'set' command)
  --timeout <seconds>   SSH connection timeout (default: 10)
  -h, --help            Show this help message
```

#### Examples

```bash
# Show current governors on all cluster nodes
./bin/clusterPerformance.sh get

# Show governors with CPU temperatures
./bin/clusterPerformance.sh get --show-temp

# Show governors for specific nodes only
./bin/clusterPerformance.sh get --nodes pve1,pve2

# List which governors are available on each node
./bin/clusterPerformance.sh list-available

# Set all nodes to performance governor
./bin/clusterPerformance.sh set performance

# Set specific nodes, backup first, log to file
./bin/clusterPerformance.sh set powersave --nodes pve1 --backup --log-file /var/log/cpugov.log

# Machine-readable JSON output
./bin/clusterPerformance.sh get --json

# Save current state to backup file
./bin/clusterPerformance.sh backup

# Restore saved state
./bin/clusterPerformance.sh restore

# Cron-friendly: set performance silently, log to syslog
./bin/clusterPerformance.sh set performance --quiet --syslog
```

#### Output Examples

**Human-readable `get`:**
```
pve1: 24x performance
pve2: 12x performance, 12x powersave (MIXED)
pve3: 24x powersave
```

**Human-readable `get --show-temp`:**
```
pve1: 24x performance (Avg temp: 45°C, Max: 52°C)
pve2: 12x performance, 12x powersave (MIXED) (Avg temp: 38°C, Max: 41°C)
```

**JSON `get --json`:**
```json
{
  "timestamp": "2026-05-01T22:00:15Z",
  "command": "get",
  "nodes": [
    {
      "name": "pve1",
      "status": "success",
      "cpus": 24,
      "governors": { "performance": 24 },
      "mixed": false,
      "available_governors": ["performance", "powersave", "ondemand", "conservative"]
    },
    {
      "name": "pve2",
      "status": "success",
      "cpus": 24,
      "governors": { "performance": 12, "powersave": 12 },
      "mixed": true,
      "available_governors": ["performance", "powersave"]
    }
  ]
}
```

**Log output (`--log-file`):**
```
[2026-05-01 22:00:15] INFO: Starting governor change: powersave
[2026-05-01 22:00:16] SUCCESS: pve1: 24 CPUs set to powersave
[2026-05-01 22:00:17] ERROR: pve2: Connection timeout
[2026-05-01 22:00:18] WARNING: pve3: Governor not available: ondemand
```

#### Backup File Format

Saved to `/etc/pve/.clusterPerformance.backup`:
```json
{
  "timestamp": "2026-05-01T22:00:15Z",
  "nodes": {
    "pve1": { "cpu0": "performance", "cpu1": "performance" },
    "pve2": { "cpu0": "performance", "cpu1": "powersave" }
  }
}
```

## Directory Structure

```
proxmox-scripts/
├── bin/                           # Executable scripts
│   ├── clusterPerformance.sh      # CPU governor management script
│   ├── clusterPerformanceGet.sh   # Legacy CPU governor status script
│   └── disk-inventory.sh          # Disk inventory script
├── includes/                      # Shared libraries and functions
│   └── disk_inventory_lib.sh
├── LICENSE
└── README.md
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

See LICENSE file for details.