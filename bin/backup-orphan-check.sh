#!/bin/bash
#
# Proxmox Backup Orphan Check Script
#
# This script scans a vzdump backup directory for backup files that belong to
# guest IDs (VMs or CTs) no longer present in Proxmox, and reports disk usage
# consumed by those orphaned backups.
#
# Usage: ./backup-orphan-check.sh [--path <dir>] [--json] [--min-age <days>]
#        [--delete-script [file]] [-h|--help]
#
# Copyright (C) 2024  jannoke
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Defaults
BACKUP_PATH="/var/lib/vz/dump"
OUTPUT_JSON=false
MIN_AGE_DAYS=0
DELETE_SCRIPT_MODE=false
DELETE_SCRIPT_FILE=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Finds vzdump backup files in a directory whose guest IDs no longer exist in
Proxmox and reports the disk space consumed by those orphaned backups.

Options:
  --path <dir>            Backup directory to scan (default: /var/lib/vz/dump)
  --json                  Output results as JSON instead of human-readable text
  --min-age <days>        Only report backups older than N days (default: 0)
  --delete-script [file]  Print rm commands for orphaned files to stdout or to
                          a file if a path is given. Does NOT delete anything.
  -h, --help              Show this help message and exit

Examples:
  $(basename "$0")
  $(basename "$0") --path /mnt/backup/dump
  $(basename "$0") --json
  $(basename "$0") --min-age 7
  $(basename "$0") --delete-script /tmp/cleanup.sh
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path)
                BACKUP_PATH="$2"
                shift 2
                ;;
            --json)
                OUTPUT_JSON=true
                shift
                ;;
            --min-age)
                MIN_AGE_DAYS="$2"
                shift 2
                ;;
            --delete-script)
                DELETE_SCRIPT_MODE=true
                # Optional next argument: if it exists and doesn't start with --, it's the file path
                if [[ -n "${2-}" && "$2" != --* ]]; then
                    DELETE_SCRIPT_FILE="$2"
                    shift
                fi
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                # Treat first bare positional argument as path (convenience)
                if [[ -z "$_POSITIONAL_CONSUMED" && "$1" != --* ]]; then
                    BACKUP_PATH="$1"
                    _POSITIONAL_CONSUMED=1
                else
                    echo -e "${RED}Unknown option: $1${NC}" >&2
                    usage >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Pure logic helpers
# ---------------------------------------------------------------------------

# Collect all active guest IDs from /etc/pve across all cluster nodes.
# Prints one numeric ID per line.
collect_active_guest_ids() {
    # VMs: /etc/pve/nodes/*/qemu-server/<VMID>.conf
    # CTs: /etc/pve/nodes/*/lxc/<CTID>.conf
    for conf in /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf; do
        [[ -e "$conf" ]] || continue
        basename "$conf" .conf
    done | sort -un
}

# Given a backup filename, extract the numeric guest ID.
# Returns empty string if the filename does not match the vzdump pattern.
extract_guest_id_from_filename() {
    local filename="$1"
    # Pattern: vzdump-{qemu|lxc}-<ID>-YYYY_MM_DD-HH-MM-SS.<ext>
    if [[ "$filename" =~ ^vzdump-(qemu|lxc)-([0-9]+)- ]]; then
        echo "${BASH_REMATCH[2]}"
    fi
}

# Given a backup filename, extract the guest type (qemu or lxc).
extract_guest_type_from_filename() {
    local filename="$1"
    if [[ "$filename" =~ ^vzdump-(qemu|lxc)-([0-9]+)- ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Format bytes into a human-readable string (B, KiB, MiB, GiB, TiB).
format_bytes() {
    local bytes="$1"
    local units=("B" "KiB" "MiB" "GiB" "TiB")
    local idx=0
    local val="$bytes"

    # Use awk for floating-point division
    awk -v b="$bytes" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        v = b; i = 1
        while (v >= 1024 && i < 5) { v = v / 1024; i++ }
        if (i == 1) printf "%d %s\n", v, u[i]
        else        printf "%.1f %s\n", v, u[i]
    }'
}

# Calculate age in days from file mtime to now.
file_age_days() {
    local filepath="$1"
    local mtime now age
    mtime=$(stat -c '%Y' "$filepath" 2>/dev/null) || { echo 0; return; }
    now=$(date +%s)
    age=$(( (now - mtime) / 86400 ))
    echo "$age"
}

# Return file size in bytes.
file_size_bytes() {
    local filepath="$1"
    stat -c '%s' "$filepath" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "                  PROXMOX BACKUP ORPHAN CHECK"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Scan Date:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Backup Path: ${BACKUP_PATH}"
    [[ "$MIN_AGE_DAYS" -gt 0 ]] && echo "Min Age:     ${MIN_AGE_DAYS} day(s)"
    echo ""
}

print_section() {
    local title="$1"
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo -e "${CYAN}${title}${NC}"
    echo "───────────────────────────────────────────────────────────────────────────"
}

# ---------------------------------------------------------------------------
# Core scan logic — populates parallel arrays used by both output modes
# ---------------------------------------------------------------------------
#
# After scan_backups returns, the following associative / indexed arrays are
# populated in the CALLER's scope (they must be declared there):
#
#   ORPHAN_IDS           — indexed array of orphaned guest IDs (sorted)
#   ORPHAN_TYPE[id]      — "qemu" | "lxc"
#   ORPHAN_FILES[id]     — newline-separated list of full file paths
#   ORPHAN_SIZES[id]     — newline-separated list of file sizes in bytes
#   ORPHAN_AGES[id]      — newline-separated list of file ages in days
#   ORPHAN_TOTAL_BYTES[id] — total bytes for that ID
#   ACTIVE_IDS_LIST      — space-separated string of active IDs (for JSON)
#   TOTAL_FILES          — total number of orphaned files
#   TOTAL_BYTES          — total bytes across all orphaned files

scan_backups() {
    local backup_path="$1"
    local min_age="$2"

    # Build lookup set of active IDs
    declare -A active_set
    while IFS= read -r id; do
        active_set["$id"]=1
    done < <(collect_active_guest_ids)

    ACTIVE_IDS_LIST="${!active_set[*]}"

    # Supported vzdump extensions
    local ext_pattern='.*\.(tar\.zst|tar\.gz|tar\.lzo|vma|vma\.zst|vma\.gz|vma\.lzo)$'

    # Scan backup directory
    declare -A seen_ids
    while IFS= read -r filepath; do
        local filename
        filename=$(basename "$filepath")

        local guest_id
        guest_id=$(extract_guest_id_from_filename "$filename")
        [[ -z "$guest_id" ]] && continue

        # Skip if guest is still active
        [[ "${active_set[$guest_id]+_}" ]] && continue

        # Age filter
        local age
        age=$(file_age_days "$filepath")
        [[ "$min_age" -gt 0 && "$age" -lt "$min_age" ]] && continue

        # Accumulate data
        local size
        size=$(file_size_bytes "$filepath")
        local gtype
        gtype=$(extract_guest_type_from_filename "$filename")

        if [[ -z "${seen_ids[$guest_id]+_}" ]]; then
            ORPHAN_IDS+=("$guest_id")
            seen_ids["$guest_id"]=1
            ORPHAN_TYPE["$guest_id"]="$gtype"
            ORPHAN_FILES["$guest_id"]="$filepath"
            ORPHAN_SIZES["$guest_id"]="$size"
            ORPHAN_AGES["$guest_id"]="$age"
            ORPHAN_TOTAL_BYTES["$guest_id"]="$size"
        else
            ORPHAN_FILES["$guest_id"]+=$'\n'"$filepath"
            ORPHAN_SIZES["$guest_id"]+=$'\n'"$size"
            ORPHAN_AGES["$guest_id"]+=$'\n'"$age"
            ORPHAN_TOTAL_BYTES["$guest_id"]=$(( ORPHAN_TOTAL_BYTES["$guest_id"] + size ))
        fi

        (( TOTAL_FILES++ ))
        (( TOTAL_BYTES += size ))

    done < <(find "$backup_path" -maxdepth 1 -type f 2>/dev/null | sort)

    # Sort orphan IDs numerically (guard against empty array)
    if [[ ${#ORPHAN_IDS[@]} -gt 0 ]]; then
        mapfile -t ORPHAN_IDS < <(printf '%s\n' "${ORPHAN_IDS[@]}" | sort -n)
    fi
}

# ---------------------------------------------------------------------------
# Human-readable output
# ---------------------------------------------------------------------------
print_human_output() {
    print_header

    if [[ ${#ORPHAN_IDS[@]} -eq 0 ]]; then
        echo -e "${GREEN}  ✓ No orphaned backups found.${NC}"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════════════"
        echo ""
        return
    fi

    print_section "Orphaned Backups by Guest ID"

    for id in "${ORPHAN_IDS[@]}"; do
        local gtype="${ORPHAN_TYPE[$id]}"
        local label="Guest ID ${id}"
        [[ -n "$gtype" ]] && label+=" (${gtype})"

        echo ""
        echo -e "  ${YELLOW}${label}${NC}"
        printf "  %-60s  %12s  %8s\n" "FILE" "SIZE" "AGE (days)"
        printf "  %-60s  %12s  %8s\n" \
            "────────────────────────────────────────────────────────────" \
            "────────────" "──────────"

        # Split parallel newline-separated lists back into arrays
        local files_arr sizes_arr ages_arr
        mapfile -t files_arr <<< "${ORPHAN_FILES[$id]}"
        mapfile -t sizes_arr <<< "${ORPHAN_SIZES[$id]}"
        mapfile -t ages_arr  <<< "${ORPHAN_AGES[$id]}"

        local i
        for (( i=0; i<${#files_arr[@]}; i++ )); do
            local fname size_h age
            fname=$(basename "${files_arr[$i]}")
            size_h=$(format_bytes "${sizes_arr[$i]}")
            age="${ages_arr[$i]}"
            printf "  %-60s  %12s  %8s\n" "$fname" "$size_h" "$age"
        done

        local subtotal_h
        subtotal_h=$(format_bytes "${ORPHAN_TOTAL_BYTES[$id]}")
        echo ""
        printf "  %s Subtotal: %s\n" "$(echo "${ORPHAN_TYPE[$id]}" | tr '[:lower:]' '[:upper:]')" "$subtotal_h"
    done

    # Summary
    print_section "Summary"

    local total_h
    total_h=$(format_bytes "$TOTAL_BYTES")

    echo -e "  Total orphaned files:  ${RED}${TOTAL_FILES}${NC}"
    echo -e "  Total orphaned size:   ${RED}${total_h}${NC}"
    echo ""

    local orphan_id_list
    orphan_id_list=$(printf '%s ' "${ORPHAN_IDS[@]}")
    echo -e "  Orphaned guest IDs:   ${YELLOW}${orphan_id_list% }${NC}"

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
}

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------
print_json_output() {
    local scan_date
    scan_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Build active_guest_ids JSON array
    local active_json=""
    local sorted_active
    mapfile -t sorted_active < <(echo "$ACTIVE_IDS_LIST" | tr ' ' '\n' | grep -v '^$' | sort -n)
    local first=true
    for aid in "${sorted_active[@]}"; do
        $first || active_json+=", "
        active_json+="$aid"
        first=false
    done

    # Build orphaned array
    local orphaned_json=""
    local first_orphan=true
    for id in "${ORPHAN_IDS[@]}"; do
        $first_orphan || orphaned_json+=","$'\n'
        first_orphan=false

        local gtype="${ORPHAN_TYPE[$id]}"
        local total_bytes="${ORPHAN_TOTAL_BYTES[$id]}"
        local total_h
        total_h=$(format_bytes "$total_bytes")

        mapfile -t files_arr <<< "${ORPHAN_FILES[$id]}"
        mapfile -t sizes_arr <<< "${ORPHAN_SIZES[$id]}"
        mapfile -t ages_arr  <<< "${ORPHAN_AGES[$id]}"

        local backups_json=""
        local first_backup=true
        local i
        for (( i=0; i<${#files_arr[@]}; i++ )); do
            $first_backup || backups_json+=","$'\n'
            first_backup=false
            local fname
            fname=$(basename "${files_arr[$i]}")
            local sz="${sizes_arr[$i]}"
            local sz_h
            sz_h=$(format_bytes "$sz")
            local age="${ages_arr[$i]}"
            backups_json+="        { \"file\": \"${fname}\", \"size_bytes\": ${sz}, \"size_human\": \"${sz_h}\", \"age_days\": ${age} }"
        done

        orphaned_json+="    {"$'\n'
        orphaned_json+="      \"guest_id\": ${id},"$'\n'
        orphaned_json+="      \"type\": \"${gtype}\","$'\n'
        orphaned_json+="      \"backups\": ["$'\n'
        orphaned_json+="${backups_json}"$'\n'
        orphaned_json+="      ],"$'\n'
        orphaned_json+="      \"total_size_bytes\": ${total_bytes},"$'\n'
        orphaned_json+="      \"total_size_human\": \"${total_h}\""$'\n'
        orphaned_json+="    }"
    done

    local total_h
    total_h=$(format_bytes "$TOTAL_BYTES")

    # Build orphaned_guest_ids JSON array
    local ogids_json=""
    local first_ogid=true
    for id in "${ORPHAN_IDS[@]}"; do
        $first_ogid || ogids_json+=", "
        ogids_json+="$id"
        first_ogid=false
    done

    cat <<EOF
{
  "scan_date": "${scan_date}",
  "backup_path": "${BACKUP_PATH}",
  "active_guest_ids": [${active_json}],
  "orphaned": [
${orphaned_json}
  ],
  "summary": {
    "total_orphaned_files": ${TOTAL_FILES},
    "total_orphaned_size_bytes": ${TOTAL_BYTES},
    "total_orphaned_size_human": "${total_h}",
    "orphaned_guest_ids": [${ogids_json}]
  }
}
EOF
}

# ---------------------------------------------------------------------------
# --delete-script output
# ---------------------------------------------------------------------------
print_delete_script() {
    local output_target="${1:-}"

    local content
    # Note: we build this with printf to avoid command-substitution stripping trailing newlines
    content="#!/bin/bash"$'\n'
    content+="# Generated by backup-orphan-check.sh on $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
    content+="# This script removes orphaned vzdump backup files from: ${BACKUP_PATH}"$'\n'
    content+="# Review carefully before executing. This cannot be undone."$'\n'
    content+=$'\n'
    for id in "${ORPHAN_IDS[@]}"; do
        mapfile -t files_arr <<< "${ORPHAN_FILES[$id]}"
        for f in "${files_arr[@]}"; do
            content+="rm '${f}'"$'\n'
        done
    done

    if [[ -n "$output_target" ]]; then
        printf '%s' "$content" > "$output_target"
        echo "Delete script written to: ${output_target}" >&2
    else
        printf '%s' "$content"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Validate backup path
    if [[ ! -d "$BACKUP_PATH" ]]; then
        echo -e "${RED}Error: Backup path does not exist or is not a directory: ${BACKUP_PATH}${NC}" >&2
        exit 1
    fi

    # Declare result containers
    declare -a ORPHAN_IDS=()
    declare -A ORPHAN_TYPE=()
    declare -A ORPHAN_FILES=()
    declare -A ORPHAN_SIZES=()
    declare -A ORPHAN_AGES=()
    declare -A ORPHAN_TOTAL_BYTES=()
    ACTIVE_IDS_LIST=""
    TOTAL_FILES=0
    TOTAL_BYTES=0

    scan_backups "$BACKUP_PATH" "$MIN_AGE_DAYS"

    if $DELETE_SCRIPT_MODE; then
        print_delete_script "$DELETE_SCRIPT_FILE"
        exit 0
    fi

    if $OUTPUT_JSON; then
        print_json_output
    else
        print_human_output
    fi
}

main "$@"
