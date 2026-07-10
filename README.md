# proxmox-scripts

A collection of useful scripts for Proxmox VE administration and management.

## Scripts

### Backup Orphan Check Script

**Location:** `bin/backup-orphan-check.sh`

Finds vzdump backup files whose guest IDs no longer exist in Proxmox and reports disk usage consumed by those orphaned backups.

> Full documentation including all flags, output examples, and how it works is in the [Backup Orphan Check Script](#backup-orphan-check-script-1) section below.

---

### Cluster CPU Performance Governor Script

**Location:** `bin/clusterPerformance.sh`

Manages CPU power governor settings (`performance`, `powersave`, etc.) across all Proxmox cluster nodes. Supports get, set, backup/restore, JSON output, logging, and CPU temperature reporting.

> Full documentation including examples, JSON output format, and backup file format is in the [Cluster CPU Performance Governor Script](#cluster-cpu-performance-governor-script-1) section below.

---

### PVE Kernel Cleaner Script

**Location:** `bin/pvekclean.sh`

Removes old Proxmox kernel packages while protecting the running kernel. Kernel discovery uses installed package names only (`pve-kernel-*`, `proxmox-kernel-*`, `pve-headers-*`, `proxmox-headers-*`) and version-aware ordering via `dpkg --compare-versions`.

> Full documentation including options and regression validation is in the [PVE Kernel Cleaner Script](#pve-kernel-cleaner-script) section below.

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

### Backup Orphan Check Script

**Location:** `bin/backup-orphan-check.sh`

Scans a vzdump backup directory for backup files whose guest IDs (VMs or CTs) no longer exist in Proxmox, and reports the disk space consumed by those orphaned backups.

#### Features

- **Automatic guest ID detection**: Reads `/etc/pve/nodes/*/qemu-server/*.conf` and `/etc/pve/nodes/*/lxc/*.conf` across all cluster nodes — no SSH required
- **All vzdump formats**: Handles `.tar.zst`, `.tar.gz`, `.tar.lzo`, `.vma`, `.vma.zst`, `.vma.gz`, `.vma.lzo` extensions
- **Grouped output**: Results grouped by orphaned guest ID with per-ID subtotals
- **JSON output**: Machine-readable JSON for scripting and monitoring pipelines
- **Age filter**: `--min-age` safety net to ignore backups younger than N days (useful for recently deleted guests)
- **Delete script generation**: Produces a ready-to-review `rm` script — never deletes anything itself
- **Color-coded display**: Consistent with other scripts in this repository

#### Requirements

- Proxmox VE 9.x
- Read access to `/etc/pve` (standard on any Proxmox cluster node)
- Root privileges (or read access to the backup directory)

#### Installation

```bash
# Clone the repository
git clone https://github.com/jannoke/proxmox-scripts.git
cd proxmox-scripts

# Make the script executable (if not already)
chmod +x bin/backup-orphan-check.sh
```

#### Usage

```
backup-orphan-check.sh [OPTIONS]

Options:
  --path <dir>            Backup directory to scan (default: /var/lib/vz/dump)
  --json                  Output results as JSON instead of human-readable text
  --min-age <days>        Only report backups older than N days (default: 0)
  --delete-script [file]  Print rm commands for orphaned files to stdout or to
                          a file if a path is given. Does NOT delete anything.
  -h, --help              Show this help message and exit
```

```bash
# Scan the default backup directory
./bin/backup-orphan-check.sh

# Scan a custom backup directory
./bin/backup-orphan-check.sh --path /mnt/backup/dump

# JSON output
./bin/backup-orphan-check.sh --json

# Only report backups older than 7 days (safety margin for recently deleted guests)
./bin/backup-orphan-check.sh --min-age 7

# Generate a deletion script for review, then execute if satisfied
./bin/backup-orphan-check.sh --delete-script /tmp/cleanup.sh
cat /tmp/cleanup.sh    # review first!
bash /tmp/cleanup.sh   # execute when ready
```

#### Output Example

```
═══════════════════════════════════════════════════════════════════════════
                  PROXMOX BACKUP ORPHAN CHECK
═══════════════════════════════════════════════════════════════════════════

Scan Date:   2026-01-15 03:00:00
Backup Path: /var/lib/vz/dump

───────────────────────────────────────────────────────────────────────────
Orphaned Backups by Guest ID
───────────────────────────────────────────────────────────────────────────

  Guest ID 200 (qemu)
  FILE                                                                  SIZE  AGE (days)
  ────────────────────────────────────────────────────────────  ────────────  ──────────
  vzdump-qemu-200-2024_01_15-03-00-01.tar.zst                       11.8 MiB        42
  vzdump-qemu-200-2024_02_20-03-00-01.tar.zst                       12.1 MiB         6

  QEMU Subtotal: 23.9 MiB

  Guest ID 201 (lxc)
  FILE                                                                  SIZE  AGE (days)
  ────────────────────────────────────────────────────────────  ────────────  ──────────
  vzdump-lxc-201-2024_01_10-03-00-01.tar.zst                        4.2 MiB        47

  LXC Subtotal: 4.2 MiB

───────────────────────────────────────────────────────────────────────────
Summary
───────────────────────────────────────────────────────────────────────────
  Total orphaned files:  3
  Total orphaned size:   28.1 MiB

  Orphaned guest IDs:   200 201

═══════════════════════════════════════════════════════════════════════════
```

#### How It Works

1. **Guest ID collection**: Reads all `.conf` filenames under `/etc/pve/nodes/*/qemu-server/` and `/etc/pve/nodes/*/lxc/` to build the full set of active guest IDs across the entire cluster
2. **Backup scanning**: Lists all files in the backup directory and extracts guest IDs from vzdump filenames using the standard naming pattern
3. **Orphan detection**: Compares backup guest IDs against the active set; any ID not found in `/etc/pve` is considered orphaned
4. **Age filtering**: Optionally skips backups newer than `--min-age` days to avoid flagging backups for recently removed guests
5. **Reporting**: Displays results grouped by guest ID with file sizes and ages, plus a summary

---

### Cluster CPU Performance Governor Script

**Location:** `bin/clusterPerformance.sh`

A comprehensive tool for managing CPU power governor settings across all nodes in a Proxmox VE cluster.

#### Features

- **Node auto-detection**: Reads `/etc/pve/corosync.conf` or `/etc/pve/.members`; falls back to `pvecm nodes` or `localhost`
- **Hostname/IP display**: Resolves each node to `hostname (IP)` format using the cluster mapping and `/etc/hosts` (no DNS lookups)
- **Get current governors**: Displays per-node CPU governor status, detecting mixed-governor nodes
- **List available governors**: Shows which governors are supported on each node
- **Set governors**: Change governor on one, several, or all nodes with optional pre-change backup and post-change verification; supports per-node governor syntax (`node1:performance,node2:powersave`)
- **Backup / Restore**: Save and restore per-CPU governor state to `/etc/pve/.clusterPerformance.backup`
- **JSON output**: Machine-readable JSON for scripting and monitoring pipelines, including `hostname`, `ip`, `display_name`, and `in_cluster` fields
- **Temperature monitoring**: Reads `/sys/class/thermal/thermal_zone*/temp` and reports average / max CPU temperature per node
- **Structured logging**: Timestamped log lines at INFO / SUCCESS / WARNING / ERROR levels; supports log file and syslog (daemon facility)
- **Quiet mode**: `-q/--quiet` suppresses stdout for cron usage
- **Configurable SSH timeout**: `--timeout <seconds>` (default: 10 s)
- **Flexible node input**: Nodes can be specified as hostnames, IP addresses, or a mix

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
  get [nodes]           Get current CPU governors (default)
  list-available [nodes]
                        List available governors per node
  set <governor> [nodes]
                        Set governor on all or specified nodes
  set <node:gov,...>    Set per-node governors (e.g. node1:performance,node2:powersave)
  backup                Save current governor state to file
  restore               Restore previously saved state

Node Selection (positional or flag, positional takes precedence):
  [nodes]               Comma-separated list (hostnames or IPs)
  --nodes node1,node2   Same as positional nodes argument
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

# Show governors for specific nodes (by hostname or IP)
./bin/clusterPerformance.sh get pve1,pve2
./bin/clusterPerformance.sh get 192.168.1.10,192.168.1.11

# List which governors are available on each node
./bin/clusterPerformance.sh list-available

# Set all nodes to performance governor
./bin/clusterPerformance.sh set performance

# Set specific nodes (positional, no --nodes flag needed)
./bin/clusterPerformance.sh set powersave pve1,pve2
./bin/clusterPerformance.sh set powersave 192.168.1.10 --backup --log-file /var/log/cpugov.log

# Set different governors per node
./bin/clusterPerformance.sh set pve1:performance,pve2:powersave

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
pve1 (192.168.1.10): 24x performance
pve2 (192.168.1.11): 12x performance, 12x powersave (MIXED)
pve3 (192.168.1.12): 24x powersave
```

**Human-readable `get --show-temp`:**
```
pve1 (192.168.1.10): 24x performance (Avg temp: 45°C, Max: 52°C)
pve2 (192.168.1.11): 12x performance, 12x powersave (MIXED) (Avg temp: 38°C, Max: 41°C)
```

**JSON `get --json`:**
```json
{
  "timestamp": "2026-05-01T22:00:15Z",
  "command": "get",
  "nodes": [
    {
      "hostname": "pve1",
      "ip": "192.168.1.10",
      "display_name": "pve1 (192.168.1.10)",
      "in_cluster": true,
      "status": "success",
      "cpus": 24,
      "governors": { "performance": 24 },
      "mixed": false,
      "available_governors": ["performance", "powersave", "ondemand", "conservative"]
    },
    {
      "hostname": "pve2",
      "ip": "192.168.1.11",
      "display_name": "pve2 (192.168.1.11)",
      "in_cluster": true,
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

## PVE Kernel Cleaner Script

**Location:** `bin/pvekclean.sh`

### Usage

```bash
./bin/pvekclean.sh [OPTIONS]
```

Key options:
- `-k, --keep [number]`
- `-rn, --remove-newer`
- `-f, --force`
- `-d, --dry-run`

### Regression Validation

Run the deterministic regression check for mixed 6.x/7.x package sets, partial-token protection, and running-kernel exclusion:

```bash
./tests/pvekclean-regression.sh
```

## Directory Structure

```
proxmox-scripts/
├── bin/                           # Executable scripts
│   ├── backup-orphan-check.sh     # Backup orphan check script
│   ├── clusterPerformance.sh      # CPU governor management script
│   ├── clusterPerformanceGet.sh   # Legacy CPU governor status script
│   ├── disk-inventory.sh          # Disk inventory script
│   └── pvekclean.sh               # PVE kernel cleaner script
├── includes/                      # Shared libraries and functions
│   └── disk_inventory_lib.sh
├── tests/
│   └── pvekclean-regression.sh    # Deterministic pvekclean regression checks
├── LICENSE
└── README.md
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

See LICENSE file for details.