#!/bin/bash
#
# Proxmox Cluster CPU Performance Governor Management Script
#
# Manages CPU power governor settings across all Proxmox cluster nodes.
#
# Usage: clusterPerformance.sh [COMMAND] [ARGUMENTS] [OPTIONS]
#
# Commands:
#   get                   Get current CPU governors (default)
#   list-available        List available governors per node
#   set <governor>        Set governor on nodes
#   backup                Save current governor state to file
#   restore               Restore previously saved state
#

# ============================================================
# Configuration
# ============================================================

SCRIPT_NAME="$(basename "$0")"
BACKUP_FILE="/etc/pve/.clusterPerformance.backup"
DEFAULT_SSH_TIMEOUT=10
SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================
# Global Variables (set by argument parsing)
# ============================================================

COMMAND="get"
GOVERNOR=""
NODES_ARG=""
ALL_NODES=true
JSON_OUTPUT=false
SHOW_TEMP=false
QUIET=false
LOG_FILE=""
USE_SYSLOG=false
SSH_TIMEOUT=$DEFAULT_SSH_TIMEOUT
DO_BACKUP=false
PER_NODE_GOVERNORS=""

# Node mapping (built at runtime from /etc/pve/corosync.conf)
declare -A NODE_HOSTNAMES  # IP -> hostname
declare -A NODE_IPS        # hostname -> IP

# ============================================================
# Logging
# ============================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_line="[$timestamp] $level: $message"

    if [ -n "$LOG_FILE" ]; then
        echo "$log_line" >> "$LOG_FILE"
    fi

    if [ "$USE_SYSLOG" = true ]; then
        local priority="daemon.info"
        case "$level" in
            ERROR)   priority="daemon.err"     ;;
            WARNING) priority="daemon.warning" ;;
        esac
        logger -p "$priority" -t "$SCRIPT_NAME" "$message"
    fi

    if [ "$QUIET" = false ] && [ "$JSON_OUTPUT" = false ]; then
        case "$level" in
            SUCCESS) echo -e "${GREEN}${log_line}${NC}" ;;
            WARNING) echo -e "${YELLOW}${log_line}${NC}" ;;
            ERROR)   echo -e "${RED}${log_line}${NC}"    ;;
            *)       echo "$log_line"                    ;;
        esac
    fi
}

log_info()    { log "INFO"    "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_warning() { log "WARNING" "$1"; }
log_error()   { log "ERROR"   "$1"; }

# ============================================================
# Node Detection
# ============================================================

get_cluster_nodes() {
    local nodes=()

    # Try corosync.conf first (ring0_addr entries)
    if [ -f /etc/pve/corosync.conf ]; then
        mapfile -t nodes < <(
            awk '/nodelist/,0' /etc/pve/corosync.conf |
            grep -oP '(?<=ring0_addr:\s)\S+' |
            sort -u
        )
        # Fallback to name: entries inside nodelist block
        if [ ${#nodes[@]} -eq 0 ]; then
            mapfile -t nodes < <(
                awk '/nodelist/,0' /etc/pve/corosync.conf |
                grep -oP '(?<=name:\s)\S+' |
                sort -u
            )
        fi
    fi

    # Try /etc/pve/.members (JSON-like)
    if [ ${#nodes[@]} -eq 0 ] && [ -f /etc/pve/.members ]; then
        mapfile -t nodes < <(
            grep -oP '"nodename"\s*:\s*"\K[^"]+' /etc/pve/.members |
            sort -u
        )
    fi

    # Try pvecm command
    if [ ${#nodes[@]} -eq 0 ] && command -v pvecm &>/dev/null; then
        mapfile -t nodes < <(
            pvecm nodes 2>/dev/null |
            awk '/^[[:space:]]*[0-9]/ {print $3}' |
            sed 's/(local)//' |
            grep -v '^$' |
            sort -u
        )
    fi

    # Final fallback: localhost
    if [ ${#nodes[@]} -eq 0 ]; then
        nodes=("localhost")
    fi

    echo "${nodes[@]}"
}

# Build NODE_HOSTNAMES (IP->hostname) and NODE_IPS (hostname->IP) from corosync.conf
build_node_mapping() {
    if [ ! -f /etc/pve/corosync.conf ]; then
        return
    fi

    local cur_name=""
    local cur_addr=""

    while IFS= read -r line; do
        # Reset on start of a new node block
        if [[ $line =~ node[[:space:]]*\{ ]]; then
            cur_name=""
            cur_addr=""
        elif [[ $line =~ name:[[:space:]]*([^[:space:]\{\}]+) ]]; then
            cur_name="${BASH_REMATCH[1]}"
        elif [[ $line =~ ring0_addr:[[:space:]]*([^[:space:]\{\}]+) ]]; then
            cur_addr="${BASH_REMATCH[1]}"
        fi
        if [[ -n "$cur_name" && -n "$cur_addr" ]]; then
            NODE_HOSTNAMES["$cur_addr"]="$cur_name"
            NODE_IPS["$cur_name"]="$cur_addr"
            cur_name=""
            cur_addr=""
        fi
    done < /etc/pve/corosync.conf
}

# ============================================================
# Remote Execution Helper
# ============================================================

run_on_node() {
    local node="$1"
    shift
    local cmd="$*"
    local local_host
    local_host="$(hostname -s 2>/dev/null)"

    # Resolve cluster hostname to its IP for reliable SSH connectivity
    local ssh_target="${NODE_IPS[$node]:-$node}"

    if [ "$node" = "localhost" ] || [ "$node" = "$local_host" ] || [ "$node" = "$(hostname 2>/dev/null)" ] || [ "$ssh_target" = "$local_host" ]; then
        bash -c "$cmd"
    else
        ssh "${SSH_BASE_OPTS[@]}" "root@${ssh_target}" "$cmd" 2>/dev/null
    fi
}

# ============================================================
# Node Name Formatting
# ============================================================

# Returns display string: "hostname (IP)", "hostname", or "IP"
# Uses cluster mapping first, then /etc/hosts (NO DNS lookups)
format_node_name() {
    local node="$1"
    local hostname ip

    # Priority 1: Known cluster hostname -> "hostname (IP)"
    if [[ -n "${NODE_IPS[$node]:-}" ]]; then
        echo "$node (${NODE_IPS[$node]})"
        return
    fi

    # Priority 2: Known cluster IP -> "hostname (IP)"
    if [[ -n "${NODE_HOSTNAMES[$node]:-}" ]]; then
        echo "${NODE_HOSTNAMES[$node]} ($node)"
        return
    fi

    # Priority 3: External node - /etc/hosts ONLY (no DNS)
    if [[ $node =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        hostname="$(grep -E "^${node}[[:space:]]" /etc/hosts | awk '{print $2}' | head -1)"
        if [[ -n "$hostname" ]]; then
            echo "$hostname ($node)"
        else
            echo "$node"
        fi
    else
        ip="$(grep -E "[[:space:]]${node}([[:space:]]|$)" /etc/hosts | awk '{print $1}' | head -1)"
        if [[ -n "$ip" ]]; then
            echo "$node ($ip)"
        else
            echo "$node"
        fi
    fi
}

# Returns pipe-separated: hostname_json|ip_json|display_name|in_cluster
# Used for JSON output fields
get_node_meta() {
    local node="$1"
    local hostname="" ip="" display_name in_cluster

    if [[ -n "${NODE_IPS[$node]:-}" ]]; then
        hostname="$node"
        ip="${NODE_IPS[$node]}"
        in_cluster="true"
    elif [[ -n "${NODE_HOSTNAMES[$node]:-}" ]]; then
        hostname="${NODE_HOSTNAMES[$node]}"
        ip="$node"
        in_cluster="true"
    else
        in_cluster="false"
        if [[ $node =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ip="$node"
            hostname="$(grep -E "^${node}[[:space:]]" /etc/hosts | awk '{print $2}' | head -1)"
        else
            hostname="$node"
            ip="$(grep -E "[[:space:]]${node}([[:space:]]|$)" /etc/hosts | awk '{print $1}' | head -1)"
        fi
    fi

    if [[ -n "$hostname" && -n "$ip" ]]; then
        display_name="$hostname ($ip)"
    elif [[ -n "$hostname" ]]; then
        display_name="$hostname"
    else
        display_name="$ip"
    fi

    local hostname_json ip_json
    [[ -n "$hostname" ]] && hostname_json="\"$hostname\"" || hostname_json="null"
    [[ -n "$ip" ]]       && ip_json="\"$ip\""             || ip_json="null"

    echo "${hostname_json}|${ip_json}|${display_name}|${in_cluster}"
}

# ============================================================
# Governor Helpers
# ============================================================

# Returns lines: "<count> <governor>" e.g. "24 performance"
get_governors_on_node() {
    local node="$1"
    run_on_node "$node" \
        "cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c"
}

# Returns space-separated list of available governors
get_available_governors_on_node() {
    local node="$1"
    run_on_node "$node" \
        "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null"
}

# Returns "<avg>:<max>" or "N/A"
get_temp_on_node() {
    local node="$1"
    run_on_node "$node" '
        temps=($(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null))
        if [ ${#temps[@]} -gt 0 ]; then
            total=0; max=0
            for t in "${temps[@]}"; do
                val=$((t / 1000))
                total=$((total + val))
                [ $val -gt $max ] && max=$val
            done
            avg=$((total / ${#temps[@]}))
            echo "${avg}:${max}"
        else
            echo "N/A"
        fi
    '
}

# Returns per-CPU lines: "<cpu>:<governor>" e.g. "cpu0:performance"
get_per_cpu_governors_on_node() {
    local node="$1"
    run_on_node "$node" '
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            cpu=$(echo "$f" | grep -oP "cpu[0-9]+")
            gov=$(cat "$f" 2>/dev/null)
            [ -n "$cpu" ] && [ -n "$gov" ] && echo "${cpu}:${gov}"
        done
    '
}

# Sets all CPUs to <governor>; outputs "SET:<count>" on success or "ERROR:<msg>"
set_governor_on_node() {
    local node="$1"
    local governor="$2"
    run_on_node "$node" "
        cpus=(\$(ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null))
        if [ \${#cpus[@]} -eq 0 ]; then
            echo 'ERROR: no cpufreq governor files found'
            exit 1
        fi
        failed=0
        for f in \"\${cpus[@]}\"; do
            echo '${governor}' > \"\$f\" 2>/dev/null || failed=\$((failed + 1))
        done
        if [ \$failed -gt 0 ]; then
            echo \"ERROR: \$failed CPU(s) could not be updated\"
            exit 1
        fi
        echo \"SET:\${#cpus[@]}\"
    "
}

# ============================================================
# JSON Helpers
# ============================================================

# Build JSON array from space-separated governor list
build_governors_json_array() {
    local govs="$1"
    local arr="["
    local first=true
    for g in $govs; do
        [ "$first" = false ] && arr+=","
        arr+="\"$g\""
        first=false
    done
    arr+="]"
    echo "$arr"
}

# ============================================================
# Command: get
# ============================================================

cmd_get() {
    local nodes=("$@")

    if [ "$JSON_OUTPUT" = true ]; then
        local timestamp
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        local json_nodes="["
        local first_node=true

        for node in "${nodes[@]}"; do
            local gov_raw
            gov_raw="$(get_governors_on_node "$node" 2>/dev/null)"

            [ "$first_node" = false ] && json_nodes+=","
            first_node=false

            local meta m_hostname_json m_ip_json m_display m_in_cluster m_rest
            meta="$(get_node_meta "$node")"
            m_hostname_json="${meta%%|*}"; m_rest="${meta#*|}"
            m_ip_json="${m_rest%%|*}";     m_rest="${m_rest#*|}"
            m_display="${m_rest%%|*}"
            m_in_cluster="${m_rest##*|}"

            if [ -z "$gov_raw" ]; then
                json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"error\",\"message\":\"Connection failed or no cpufreq support\"}"
                continue
            fi

            local cpu_count=0
            local mixed=false
            local gov_json="{"
            local first_gov=true
            local gov_count=0

            while read -r cnt gov; do
                [ -z "$gov" ] && continue
                [ "$first_gov" = false ] && gov_json+=","
                gov_json+="\"$gov\":$cnt"
                first_gov=false
                cpu_count=$((cpu_count + cnt))
                gov_count=$((gov_count + 1))
            done <<< "$gov_raw"
            gov_json+="}"

            [ $gov_count -gt 1 ] && mixed=true

            local avail
            avail="$(get_available_governors_on_node "$node" 2>/dev/null)"
            local avail_json
            avail_json="$(build_governors_json_array "$avail")"

            local mixed_str="false"
            [ "$mixed" = true ] && mixed_str="true"

            json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"success\",\"cpus\":$cpu_count,\"governors\":$gov_json,\"mixed\":$mixed_str,\"available_governors\":$avail_json}"
        done

        json_nodes+="]"
        echo "{\"timestamp\":\"$timestamp\",\"command\":\"get\",\"nodes\":$json_nodes}"
        return
    fi

    for node in "${nodes[@]}"; do
        local gov_raw
        gov_raw="$(get_governors_on_node "$node" 2>/dev/null)"

        local display
        display="$(format_node_name "$node")"

        if [ -z "$gov_raw" ]; then
            log_error "$display: Connection failed or no cpufreq support"
            continue
        fi

        local cpu_count=0
        local gov_display=""
        local gov_count=0

        while read -r cnt gov; do
            [ -z "$gov" ] && continue
            [ -n "$gov_display" ] && gov_display+=", "
            gov_display+="${cnt}x ${gov}"
            cpu_count=$((cpu_count + cnt))
            gov_count=$((gov_count + 1))
        done <<< "$gov_raw"

        local status=""
        [ $gov_count -gt 1 ] && status=" ${YELLOW}(MIXED)${NC}"

        local temp_str=""
        if [ "$SHOW_TEMP" = true ]; then
            local temp_raw
            temp_raw="$(get_temp_on_node "$node" 2>/dev/null)"
            if [ -n "$temp_raw" ] && [ "$temp_raw" != "N/A" ]; then
                local avg_temp="${temp_raw%%:*}"
                local max_temp="${temp_raw##*:}"
                temp_str=" (Avg temp: ${avg_temp}°C, Max: ${max_temp}°C)"
            fi
        fi

        echo -e "${display}: ${gov_display}${status}${temp_str}"
    done
}

# ============================================================
# Command: list-available
# ============================================================

cmd_list_available() {
    local nodes=("$@")

    if [ "$JSON_OUTPUT" = true ]; then
        local timestamp
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        local json_nodes="["
        local first_node=true

        for node in "${nodes[@]}"; do
            local avail
            avail="$(get_available_governors_on_node "$node" 2>/dev/null)"

            [ "$first_node" = false ] && json_nodes+=","
            first_node=false

            local meta m_hostname_json m_ip_json m_display m_in_cluster m_rest
            meta="$(get_node_meta "$node")"
            m_hostname_json="${meta%%|*}"; m_rest="${meta#*|}"
            m_ip_json="${m_rest%%|*}";     m_rest="${m_rest#*|}"
            m_display="${m_rest%%|*}"
            m_in_cluster="${m_rest##*|}"

            if [ -z "$avail" ]; then
                json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"error\",\"available_governors\":[]}"
            else
                local avail_json
                avail_json="$(build_governors_json_array "$avail")"
                json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"success\",\"available_governors\":$avail_json}"
            fi
        done

        json_nodes+="]"
        echo "{\"timestamp\":\"$timestamp\",\"command\":\"list-available\",\"nodes\":$json_nodes}"
        return
    fi

    for node in "${nodes[@]}"; do
        local avail
        avail="$(get_available_governors_on_node "$node" 2>/dev/null)"
        local display
        display="$(format_node_name "$node")"
        if [ -z "$avail" ]; then
            log_error "$display: Could not retrieve available governors"
        else
            echo "$display: $avail"
        fi
    done
}

# ============================================================
# Command: set
# ============================================================

cmd_set() {
    local governor="$1"
    shift
    local nodes=("$@")

    # ── Per-node governor mode: set node1:perf,node2:pow ──────────────────
    if [ -n "$PER_NODE_GOVERNORS" ]; then
        log_info "Starting per-node governor changes"

        if [ "$DO_BACKUP" = true ]; then
            log_info "Backing up current governor state before change..."
            cmd_backup "${nodes[@]}"
        fi

        if [ "$JSON_OUTPUT" = true ]; then
            local timestamp
            timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            local json_nodes="["
            local first_node=true

            local pair pnode pgov
            IFS=',' read -ra pairs <<< "$PER_NODE_GOVERNORS"
            for pair in "${pairs[@]}"; do
                pnode="${pair%%:*}"
                pgov="${pair#*:}"

                [ "$first_node" = false ] && json_nodes+=","
                first_node=false

                local meta m_hostname_json m_ip_json m_display m_in_cluster m_rest
                meta="$(get_node_meta "$pnode")"
                m_hostname_json="${meta%%|*}"; m_rest="${meta#*|}"
                m_ip_json="${m_rest%%|*}";     m_rest="${m_rest#*|}"
                m_display="${m_rest%%|*}"
                m_in_cluster="${m_rest##*|}"

                local avail
                avail="$(get_available_governors_on_node "$pnode" 2>/dev/null)"
                if [ -n "$avail" ] && ! echo " $avail " | grep -qw "$pgov"; then
                    json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"error\",\"message\":\"Governor not available: $pgov\",\"available_governors\":$(build_governors_json_array "$avail")}"
                    continue
                fi

                local result
                result="$(set_governor_on_node "$pnode" "$pgov" 2>/dev/null)"
                if echo "$result" | grep -q "^SET:"; then
                    local count="${result#SET:}"
                    json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"success\",\"cpus\":$count,\"governor\":\"$pgov\"}"
                else
                    local err_msg="${result#ERROR: }"
                    json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"error\",\"message\":\"${err_msg:-Connection timeout}\"}"
                fi
            done

            json_nodes+="]"
            echo "{\"timestamp\":\"$timestamp\",\"command\":\"set\",\"nodes\":$json_nodes}"
            return
        fi

        local success_count=0
        IFS=',' read -ra pairs <<< "$PER_NODE_GOVERNORS"
        for pair in "${pairs[@]}"; do
            pnode="${pair%%:*}"
            pgov="${pair#*:}"
            local display
            display="$(format_node_name "$pnode")"

            local avail
            avail="$(get_available_governors_on_node "$pnode" 2>/dev/null)"
            if [ -n "$avail" ] && ! echo " $avail " | grep -qw "$pgov"; then
                log_warning "$display: Governor not available: $pgov"
                continue
            fi

            local result
            result="$(set_governor_on_node "$pnode" "$pgov" 2>/dev/null)"
            if echo "$result" | grep -q "^SET:"; then
                local count="${result#SET:}"
                log_success "$display: ${count} CPUs set to $pgov"
                success_count=$((success_count + 1))
            elif echo "$result" | grep -q "^ERROR:"; then
                local err_msg="${result#ERROR: }"
                log_error "$display: $err_msg"
            else
                log_error "$display: Connection timeout"
            fi
        done

        if [ $success_count -gt 0 ]; then
            log_info "Verifying governor changes..."
            cmd_get "${nodes[@]}"
        fi
        return
    fi

    # ── Standard mode: same governor for all nodes ────────────────────────
    if [ -z "$governor" ]; then
        log_error "No governor specified for 'set' command"
        usage
        exit 1
    fi

    log_info "Starting governor change: $governor"

    if [ "$DO_BACKUP" = true ]; then
        log_info "Backing up current governor state before change..."
        cmd_backup "${nodes[@]}"
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        local timestamp
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        local json_nodes="["
        local first_node=true

        for node in "${nodes[@]}"; do
            local avail
            avail="$(get_available_governors_on_node "$node" 2>/dev/null)"

            [ "$first_node" = false ] && json_nodes+=","
            first_node=false

            local meta m_hostname_json m_ip_json m_display m_in_cluster m_rest
            meta="$(get_node_meta "$node")"
            m_hostname_json="${meta%%|*}"; m_rest="${meta#*|}"
            m_ip_json="${m_rest%%|*}";     m_rest="${m_rest#*|}"
            m_display="${m_rest%%|*}"
            m_in_cluster="${m_rest##*|}"

            if [ -n "$avail" ] && ! echo " $avail " | grep -qw "$governor"; then
                json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"error\",\"message\":\"Governor not available: $governor\",\"available_governors\":$(build_governors_json_array "$avail")}"
                continue
            fi

            local result
            result="$(set_governor_on_node "$node" "$governor" 2>/dev/null)"

            if echo "$result" | grep -q "^SET:"; then
                local count="${result#SET:}"
                json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"success\",\"cpus\":$count,\"governor\":\"$governor\"}"
            else
                local err_msg="${result#ERROR: }"
                json_nodes+="{\"hostname\":${m_hostname_json},\"ip\":${m_ip_json},\"display_name\":\"${m_display}\",\"in_cluster\":${m_in_cluster},\"status\":\"error\",\"message\":\"${err_msg:-Connection timeout}\"}"
            fi
        done

        json_nodes+="]"
        echo "{\"timestamp\":\"$timestamp\",\"command\":\"set\",\"governor\":\"$governor\",\"nodes\":$json_nodes}"
        return
    fi

    local success_count=0

    for node in "${nodes[@]}"; do
        local avail
        avail="$(get_available_governors_on_node "$node" 2>/dev/null)"
        local display
        display="$(format_node_name "$node")"

        if [ -n "$avail" ] && ! echo " $avail " | grep -qw "$governor"; then
            log_warning "$display: Governor not available: $governor"
            continue
        fi

        local result
        result="$(set_governor_on_node "$node" "$governor" 2>/dev/null)"

        if echo "$result" | grep -q "^SET:"; then
            local count="${result#SET:}"
            log_success "$display: ${count} CPUs set to $governor"
            success_count=$((success_count + 1))
        elif echo "$result" | grep -q "^ERROR:"; then
            local err_msg="${result#ERROR: }"
            log_error "$display: $err_msg"
        else
            log_error "$display: Connection timeout"
        fi
    done

    # Verify changes
    if [ $success_count -gt 0 ]; then
        log_info "Verifying governor changes..."
        cmd_get "${nodes[@]}"
    fi
}

# ============================================================
# Command: backup
# ============================================================

cmd_backup() {
    local nodes=("$@")
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local json="{\"timestamp\":\"$timestamp\",\"nodes\":{"
    local first_node=true

    for node in "${nodes[@]}"; do
        local cpu_govs
        cpu_govs="$(get_per_cpu_governors_on_node "$node" 2>/dev/null)"

        [ "$first_node" = false ] && json+=","
        first_node=false
        json+="\"$node\":{"

        local first_cpu=true
        while IFS=: read -r cpu gov; do
            [ -z "$cpu" ] || [ -z "$gov" ] && continue
            [ "$first_cpu" = false ] && json+=","
            json+="\"$cpu\":\"$gov\""
            first_cpu=false
        done <<< "$cpu_govs"

        json+="}"
    done

    json+="}}"

    if echo "$json" > "$BACKUP_FILE"; then
        log_success "Governor state backed up to $BACKUP_FILE"
    else
        log_error "Failed to write backup to $BACKUP_FILE"
        return 1
    fi
}

# ============================================================
# Command: restore
# ============================================================

cmd_restore() {
    local nodes=("$@")

    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    log_info "Restoring governor state from $BACKUP_FILE"
    local backup_content
    backup_content="$(cat "$BACKUP_FILE")"

    for node in "${nodes[@]}"; do
        # Extract per-CPU governor pairs for this node from compact JSON
        local node_section
        node_section="$(echo "$backup_content" | grep -oP "\"${node}\":\{[^}]*\}" | head -1)"

        if [ -z "$node_section" ]; then
            log_warning "$(format_node_name "$node"): No backup data found for this node"
            continue
        fi

        # Build a restore script: one echo per CPU
        local restore_cmds=""
        while IFS= read -r pair; do
            local cpu gov
            cpu="$(echo "$pair" | grep -oP '^"[^"]+"' | tr -d '"')"
            gov="$(echo "$pair" | grep -oP '"[^"]+"$' | tr -d '"')"
            [ -z "$cpu" ] || [ -z "$gov" ] && continue
            restore_cmds+="echo '${gov}' > /sys/devices/system/cpu/${cpu}/cpufreq/scaling_governor 2>/dev/null || echo FAIL:${cpu}; "
        done < <(echo "$node_section" | grep -oP '"cpu[0-9]+":"[^"]*"')

        if [ -z "$restore_cmds" ]; then
            log_warning "$(format_node_name "$node"): Backup data is empty or unreadable"
            continue
        fi

        local result
        result="$(run_on_node "$node" "$restore_cmds" 2>/dev/null)"

        if echo "$result" | grep -q "^FAIL:"; then
            local failed_cpus
            failed_cpus="$(echo "$result" | grep "^FAIL:" | sed 's/^FAIL://' | tr '\n' ' ')"
            log_warning "$(format_node_name "$node"): Failed to restore CPUs: $failed_cpus"
        else
            log_success "$(format_node_name "$node"): Governor state restored"
        fi
    done
}

# ============================================================
# Usage
# ============================================================

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [COMMAND] [ARGUMENTS] [OPTIONS]

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
  [nodes]               Comma-separated list of nodes (hostnames or IPs)
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
  --timeout <seconds>   SSH connection timeout (default: $DEFAULT_SSH_TIMEOUT)
  -h, --help            Show this help message

Log format:
  [YYYY-MM-DD HH:MM:SS] LEVEL: message
  Levels: INFO, SUCCESS, WARNING, ERROR

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME get
  $SCRIPT_NAME get node1,node2 --show-temp
  $SCRIPT_NAME get 192.168.1.10,192.168.1.11
  $SCRIPT_NAME list-available
  $SCRIPT_NAME set performance
  $SCRIPT_NAME set powersave node1,node2
  $SCRIPT_NAME set powersave 192.168.1.10 --backup
  $SCRIPT_NAME set node1:performance,node2:powersave
  $SCRIPT_NAME set performance --json
  $SCRIPT_NAME backup
  $SCRIPT_NAME restore
  $SCRIPT_NAME get --json
  $SCRIPT_NAME set performance --log-file /var/log/cpugov.log --quiet

Backup file: $BACKUP_FILE
EOF
}

# ============================================================
# Argument Parsing
# ============================================================

parse_args() {
    local -a positional=()

    while [ $# -gt 0 ]; do
        case "$1" in
            get|list-available|backup|restore)
                COMMAND="$1"
                shift
                ;;
            set)
                COMMAND="set"
                shift
                ;;
            --nodes)
                if [ -z "${2:-}" ]; then
                    log_error "--nodes requires a value"
                    exit 1
                fi
                NODES_ARG="$2"
                ALL_NODES=false
                shift 2
                ;;
            --all)
                ALL_NODES=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --show-temp)
                SHOW_TEMP=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            --log-file)
                if [ -z "${2:-}" ]; then
                    log_error "--log-file requires a path"
                    exit 1
                fi
                LOG_FILE="$2"
                shift 2
                ;;
            --syslog)
                USE_SYSLOG=true
                shift
                ;;
            --backup)
                DO_BACKUP=true
                shift
                ;;
            --timeout)
                if [ -z "${2:-}" ] || ! [[ "${2}" =~ ^[0-9]+$ ]]; then
                    log_error "--timeout requires a numeric value"
                    exit 1
                fi
                SSH_TIMEOUT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    # Process positional arguments
    if [ "$COMMAND" = "set" ]; then
        if [ ${#positional[@]} -ge 1 ]; then
            local first="${positional[0]}"
            # Per-node governor syntax: node1:gov1,node2:gov2
            if echo "$first" | grep -q ":"; then
                PER_NODE_GOVERNORS="$first"
            else
                GOVERNOR="$first"
                # Second positional arg is an optional nodes list
                if [ ${#positional[@]} -ge 2 ] && [ -z "$NODES_ARG" ]; then
                    NODES_ARG="${positional[1]}"
                    ALL_NODES=false
                fi
            fi
        fi
    else
        # For get / list-available / backup / restore
        if [ ${#positional[@]} -ge 1 ] && [ -z "$NODES_ARG" ]; then
            NODES_ARG="${positional[0]}"
            ALL_NODES=false
        fi
    fi
}

# ============================================================
# Main
# ============================================================

main() {
    parse_args "$@"

    # Rebuild SSH options with configured timeout
    SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout="${SSH_TIMEOUT}")

    # Build hostname<->IP mapping from /etc/pve/corosync.conf (no-op if file absent)
    build_node_mapping

    # Determine nodes
    local nodes=()
    if [ "$COMMAND" = "set" ] && [ -n "$PER_NODE_GOVERNORS" ]; then
        # Per-node mode: extract node identifiers from the pairs
        local pair
        IFS=',' read -ra pairs <<< "$PER_NODE_GOVERNORS"
        for pair in "${pairs[@]}"; do
            nodes+=("${pair%%:*}")
        done
    elif [ -n "$NODES_ARG" ]; then
        IFS=',' read -ra nodes <<< "$NODES_ARG"
    else
        mapfile -t nodes < <(get_cluster_nodes | tr ' ' '\n' | grep -v '^$')
    fi

    if [ ${#nodes[@]} -eq 0 ]; then
        log_error "No nodes found"
        exit 1
    fi

    case "$COMMAND" in
        get)
            cmd_get "${nodes[@]}"
            ;;
        list-available)
            cmd_list_available "${nodes[@]}"
            ;;
        set)
            cmd_set "$GOVERNOR" "${nodes[@]}"
            ;;
        backup)
            cmd_backup "${nodes[@]}"
            ;;
        restore)
            cmd_restore "${nodes[@]}"
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
