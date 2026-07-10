#!/bin/bash
: '
______________________________________________

              PVE Kernel Cleaner
               By Jordan Hillis
             jordan@hillis.email
           https://jordanhillis.com
______________________________________________

MIT License

Copyright (c) 2023 Jordan Hillis - jordan@hillis.email - https://jordanhillis.com

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
______________________________________________
'

# Percentage of used space in the /boot which would consider it critically full
boot_critical_percent="80"

# To check for updates or not
check_for_updates=true

# Dry run mode is for testing without actually removing anything
dry_run=false

# Current kernel
current_kernel="${PVEKCLEAN_TEST_CURRENT_KERNEL:-$(uname -r)}"

# Name of the program
program_name="pvekclean"

# Version
version="2.0.2"

# Text Colors
black="\e[38;2;0;0;0m"
gray="\e[30m"
red="\e[31m"
green="\e[32m"
yellow="\e[33m"
blue="\e[34m"
magenta="\e[35m"
cyan="\e[36m"
white="\e[37m"
orange="\e[38;5;202m"

# Background Colors
bg_black="\e[40m"
bg_red="\e[41m"
bg_green="\e[42m"
bg_yellow="\e[43m"
bg_blue="\e[44m"
bg_magenta="\e[45m"
bg_cyan="\e[46m"
bg_white="\e[47m"
bg_orange="\e[48;5;202m"

# Text Styles
bold="\e[1m"

# Reset formatting
reset="\e[0m"

# Force purging without dialog confirms
force_purge=false

# Allow removing kernels newer than current
remove_newer=false

# Check if script is ran as root, if not exit
check_root() {
	if [ "${PVEKCLEAN_ALLOW_NON_ROOT:-false}" == "true" ]; then
		return
	fi
	if [[ $EUID -ne 0 ]]; then
		printf "${bold}[!] Error:${reset} this script must be ran as the root user.\n"
		exit 1
	fi
}

get_installed_kernel_related_packages() {
	if [ -n "${PVEKCLEAN_TEST_DPKG_QUERY_FILE:-}" ] && [ -f "${PVEKCLEAN_TEST_DPKG_QUERY_FILE}" ]; then
		awk '$2=="install" && $3=="ok" && $4=="installed" && $1 ~ /^(pve|proxmox)-(kernel|headers)-/ {print $1}' "${PVEKCLEAN_TEST_DPKG_QUERY_FILE}"
		return
	fi
	dpkg-query -W -f='${Package}\t${Status}\n' 2>/dev/null | awk '$2=="install" && $3=="ok" && $4=="installed" && $1 ~ /^(pve|proxmox)-(kernel|headers)-/ {print $1}'
}

extract_kernel_id_from_package() {
	local package_name="$1"
	if [[ "$package_name" =~ ^(pve|proxmox)-kernel-([0-9]+(\.[0-9]+){2,}-[0-9]+-pve(-signed)?)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

kernel_version_key() {
	printf '%s\n' "${1%-signed}"
}

kernel_id_lt() {
	local a="$1"
	local b="$2"
	local a_key
	local b_key
	a_key="$(kernel_version_key "$a")"
	b_key="$(kernel_version_key "$b")"
	if dpkg --compare-versions "$a_key" lt "$b_key"; then
		return 0
	fi
	if dpkg --compare-versions "$a_key" gt "$b_key"; then
		return 1
	fi
	[[ "$a" < "$b" ]]
}

insert_sorted_kernel_id() {
	local id="$1"
	local inserted=false
	local item
	for item in "${sorted_kernel_ids[@]}"; do
		if [ "$item" == "$id" ]; then
			return
		fi
	done
	for i in "${!sorted_kernel_ids[@]}"; do
		if kernel_id_lt "$id" "${sorted_kernel_ids[$i]}"; then
			sorted_kernel_ids=("${sorted_kernel_ids[@]:0:$i}" "$id" "${sorted_kernel_ids[@]:$i}")
			inserted=true
			break
		fi
	done
	if [ "$inserted" == "false" ]; then
		sorted_kernel_ids+=("$id")
	fi
}

collect_sorted_kernel_ids() {
	sorted_kernel_ids=()
	local pkg
	local kernel_id
	while IFS= read -r pkg; do
		[ -z "$pkg" ] && continue
		if kernel_id="$(extract_kernel_id_from_package "$pkg")"; then
			insert_sorted_kernel_id "$kernel_id"
		fi
	done < <(get_installed_kernel_related_packages)
	printf '%s\n' "${sorted_kernel_ids[@]}"
}

is_running_kernel_variant() {
	local kernel_id="$1"
	local running_base="${current_kernel%-signed}"
	local candidate_base="${kernel_id%-signed}"
	[ "$candidate_base" == "$running_base" ]
}

get_latest_installed_kernel() {
	local kernels
	mapfile -t kernels < <(collect_sorted_kernel_ids)
	if [ "${#kernels[@]}" -gt 0 ]; then
		printf '%s\n' "${kernels[-1]}"
	fi
}

collect_packages_for_kernel_id() {
	local kernel_id="$1"
	local kernel_base="${kernel_id%-signed}"
	local pkg
	local suffix
	while IFS= read -r pkg; do
		[ -z "$pkg" ] && continue
		case "$pkg" in
			pve-kernel-*|proxmox-kernel-*|pve-headers-*|proxmox-headers-*) ;;
			*) continue ;;
		esac
		suffix="$pkg"
		suffix="${suffix#pve-kernel-}"
		suffix="${suffix#proxmox-kernel-}"
		suffix="${suffix#pve-headers-}"
		suffix="${suffix#proxmox-headers-}"
		if [[ "$suffix" =~ ^[0-9]+(\.[0-9]+){2,}-[0-9]+-pve(-signed)?$ ]] && { [ "$suffix" == "$kernel_base" ] || [ "$suffix" == "${kernel_base}-signed" ]; }; then
			printf '%s\n' "$pkg"
		fi
	done < <(get_installed_kernel_related_packages)
}

# Shown current version
version() {
  printf $version"\n"
  exit 0
}

# Header for PVE Kernel Cleaner
header_info() {
echo -e " ${bg_black}${orange}                                                ${reset}
 ${bg_black}${orange}   █▀▀█ ▀█ █▀ █▀▀   █ █ █▀▀ █▀▀█ █▀▀▄ █▀▀ █     ${reset}
 ${bg_black}${orange}   █  █  █▄█  █▀▀   █▀▄ █▀▀ █▄▄▀ █  █ █▀▀ █     ${reset} 
 ${bg_black}${orange}   █▀▀▀   ▀   ▀▀▀   ▀ ▀ ▀▀▀ ▀ ▀▀ ▀  ▀ ▀▀▀ ▀▀▀   ${reset}
 ${bg_black}${orange}                                                ${reset}
 ${bg_black}${white}   █▀▀ █   █▀▀ █▀▀█ █▀▀▄ █▀▀ █▀▀█               ${reset}
 ${bg_black}${white}   █   █   █▀▀ █▄▄█ █  █ █▀▀ █▄▄▀  ${white}${bold}⎦˚◡˚⎣ v$version ${reset}
 ${bg_black}${white}   ▀▀▀ ▀▀▀ ▀▀▀ ▀  ▀ ▀  ▀ ▀▀▀ ▀ ▀▀               ${reset}
 ${bg_orange}${black}      ${bold}By Jordan Hillis [jordan@hillis.email]    ${reset}
___________________________________________
"
if [ "$dry_run" == "true" ]; then
	printf "          ${bg_yellow}${black}${bold}    DRY RUN MODE IS: ${red}ON    ${reset}\n"
	printf "${bg_green}${bold}${black} This is what the script would do in regular mode ${reset}\n${bg_green}${bold}${black}      (but without making actual changes)         ${reset}\n\n"
fi
}

# Function to get drive status based on usage percentage
get_drive_status() {
	local usage=$1
    # Check if the input is a number
    if ! [[ $usage =~ ^[0-9]+$ ]]; then
        echo "${bold}N/A${reset}"
    else
		if (( usage <= 50 )); then
			echo "${bold}${green}Healthy${reset}"
		elif (( usage > 50 && usage <= 75 )); then
			echo "${bold}${orange}Moderate Capacity${reset}"
		else
			echo "${bold}${red}Critically Full${reset}"
		fi
	fi
}

# Show current system information
kernel_info() {
	# Lastest kernel installed
	latest_kernel="$(get_latest_installed_kernel)"
	[ -z "$latest_kernel" ] && latest_kernel="N/A"
	# Show operating system used
	printf " ${bold}OS:${reset} $(cat /etc/os-release | grep "PRETTY_NAME" | sed 's/PRETTY_NAME=//g' | sed 's/["]//g' | awk '{print $0}')\n"
	# Get information about the /boot folder
	boot_info=($(echo $(df -Ph | grep /boot | tail -1) | sed 's/%//g'))
	# Show information about the /boot
	printf " ${bold}Boot Disk:${reset} ${boot_info[4]}%% full [${boot_info[2]}/${boot_info[1]} used, ${boot_info[3]} free] \n"
	# Show current kernel in use
	printf " ${bold}Current Kernel:${reset} $current_kernel\n"
	# Check if they are running a PVE kernel
	if [[ "$current_kernel" == *"pve"* ]]; then
		# Check if we are running the latest kernel, if not warn
		if [[ "$latest_kernel" != "$current_kernel" ]] && [[ "$latest_kernel" != "${current_kernel}-signed" ]]; then
			printf " ${bold}Latest Kernel:${reset} ${latest_kernel}\n"
		fi
	# Warn them that they aren't on a PVE kernel
	else
		printf "___________________________________________\n\n"
		printf "${bold}[!]${reset} Warning, you're not running a PVE kernel\n"
		# Ask them if they want to continue
		printf "${bold}[*]${reset} Would you like to continue [y/N] "
		read -n 1 -r
		printf "\n"
		if [[ $REPLY =~ ^[Yy]$ ]]; then
			# Continue on if they wish
			printf "${bold}[-]${reset} Alright, we will continue on\n"
		else
			# Exit script
			printf "\nGood bye!\n"
			exit 0
		fi
	fi
	printf "___________________________________________\n\n"
}

# Usage information on how to use PVE Kernel Clean
show_usage() {
	# Skip showing usage when force_purge is enabled
	if [ $force_purge == false ]; then
		printf "${bold}Usage:${reset} $(basename $0) [OPTION1] [OPTION2]...\n\n"
		printf "  -k, --keep [number]   Keep the specified number of most recent PVE kernels on the system\n"
		printf "                        Can be used with -f or --force for non-interactive removal\n"
		printf "  -f, --force           Force the removal of old PVE kernels without confirm prompts\n"
		printf "  -rn, --remove-newer   Remove kernels that are newer than the currently running kernel\n"
		printf "  -s, --scheduler       Have old PVE kernels removed on a scheduled basis\n"
		printf "  -v, --version         Shows current version of $program_name\n"
		printf "  -r, --remove          Uninstall $program_name from the system\n"
		printf "  -i, --install         Install $program_name to the system\n"
		printf "  -d, --dry-run         Run the program in dry run mode for testing without making system changes\n"
		printf "___________________________________________\n\n"
	fi
}

# Schedule PVE Kernel Cleaner at a time desired
scheduler() {
	# Check if pvekclean is on the system, if not exit
	if [ ! -f /usr/local/sbin/$program_name ]; then
		printf "${bold}[!]${reset} Sorry $program_name is required to be installed on the system for this functionality.\n"
		exit 1
	fi
	# Check if cron is installed
    if ! [ -x "$(command -v crontab)" ]; then
      printf "${bold}[*]${reset} Error, cron does not appear to be installed.\n"
      printf "    Please install cron with the command 'sudo apt-get install cron'\n\n"
      exit 1
    fi
	# Check if the cronjob exists on the system
	check_cron_exists=$(crontab -l | grep "$program_name")
	# Cronjob exists
	if [ -n "$check_cron_exists" ]; then
		# Get the current cronjob scheduling
		cron_current=$(crontab -l | grep "$program_name" | sed "s/[^a-zA-Z']/ /g" | sed -e "s/\b\(.\)/\u\1/g" | awk '{print $1;}')
		# Ask the user if they would like to remove the scheduling
		printf "${bold}[-]${reset} Would you like to remove the currently scheduled PVE Kernel Cleaner? (Current: $cron_current) [y/N] "
		read -n 1 -r
		if [[ $REPLY =~ ^[Yy]$ ]]; then
			# Remove the cronjob
			(crontab -l | grep -v "$program_name")| crontab -
			printf "\n[*] Successfully removed the ${cron_current,,} scheduled PVE Kernel Cleaner!\n"
		else
			# Keep it
			printf "\n\nAlright we will keep your current settings then.\n"
		fi
	# Cronjob does not exist
	else
		# Ask how often the would like to check for old PVE kernels
		printf "${bold}[-]${reset} How often would you like to check for old PVE kernels?\n    1) Daily\n    2) Weekly\n    3) Monthly\n\n  - Enter a number option above? "
		read -r -p "" response
		case "$response" in
			1)
				cron_time="daily"
			;;
			2)
				cron_time="weekly"
			;;
			3)
				cron_time="monthly"
			;;
			*)
				printf "\nThat is not a valid option!\n"
				exit 1
			;;
		esac
		# Ask if they want to set a specific number of kernels to keep
        printf "${bold}[-]${reset} Enter the number of latest kernels to keep (or press Enter to skip): "
		read number_of_kernels
        if [[ "$number_of_kernels" =~ ^[0-9]+$ ]]; then
            kernel_option=" -k $number_of_kernels"
			printf "${bold}[-]${reset} Okay, we will keep at least $number_of_kernels kernels on the system."
        else
            kernel_option=""
        fi
		# Add the cronjob
		(crontab -l ; echo "@$cron_time /usr/local/sbin/$program_name -f$kernel_option")| crontab -
		printf "\n[-] Scheduled $cron_time PVE Kernel Cleaner successfully!\n"
	fi
	exit 0
}

# Installs PVE Kernel Cleaner for easier access
install_program() {
	force_pvekclean_update=false
    local tmp_file="/tmp/.pvekclean_install_lock"
    local install=false
    local ask_interval=3600  # 1 hour in seconds	
	# If pvekclean exists on the system
	if [ -e /usr/local/sbin/$program_name ]; then
		# Get current version of pvekclean
		pvekclean_installed_version=$(/usr/local/sbin/$program_name -v | awk '{printf $0}')
		# If the version differs, update it to the latest from the script
		if [ $version != $pvekclean_installed_version ] && [ $force_purge == false ]; then
			printf "${bold}[!]${reset} A new version of PVE Kernel Cleaner has been detected (Installed: $pvekclean_installed_version | New: $version).\n"
			printf "${bold}[*]${reset} Installing update...\n"
			force_pvekclean_update=true
		fi
	fi
    # Check if the file doesn't exist or it's been over an hour since the last ask
    if [ ! -e "$tmp_file" ] || [ ! -f "$tmp_file" ] || [ $(( $(date +%s) - $(cat "$tmp_file") )) -gt $ask_interval ] || [ $force_pvekclean_update == true ] || [ -n "$force_pvekclean_install" ]; then	
		# If pvekclean does not exist on the system or force_purge is enabled
		if [ ! -f /usr/local/sbin/$program_name ] || [ $force_pvekclean_update == true ] || [ -n "$force_pvekclean_install" ]; then
			# Ask user if we can install it to their system
			if [ $force_purge == true ]; then
				REPLY="n"
			else
				# Update the timestamp in the file to record the time of the last ask
				echo $(date +%s) > "$tmp_file"
				# Ask if we can install it
				printf "${bold}[-]${reset} Can we install PVE Kernel Cleaner to your /usr/local/sbin for easier access [y/N] " 
				read -n 1 -r
				printf "\n"
			fi
			# User agrees to have it installed
			if [[ $REPLY =~ ^[Yy]$ ]]; then
				# Copy the script to /usr/local/sbin and set execution permissions
				cp $0 /usr/local/sbin/$program_name
				chmod +x /usr/local/sbin/$program_name
				# Tell user how to use it
				printf "${bold}[*]${reset} Installed PVE Kernel Cleaner to /usr/local/sbin/$program_name\n"
				printf "${bold}[*]${reset} Run the command \"$program_name\" to begin using this program.\n"
				printf "${bold}[-]${reset} Run the command \"$program_name -r\" to remove this program at any time.\n"
				exit 0
			fi
		fi
	fi
	if [ -n "$force_pvekclean_install" ]; then
		exit 0
	fi
}

# Uninstall pvekclean from the system
uninstall_program() {
	# If pvekclean exists on the system
	if [ -e /usr/local/sbin/$program_name ]; then
		# Confirm that they wish to remove it
		printf "${bold}[-]${reset} Are you sure that you would like to remove $program_name? [y/N] "
		read -n 1 -r
		printf "\n"
		if [[ $REPLY =~ ^[Yy]$ ]]; then
			# Remove the program
			rm -f /usr/local/sbin/$program_name
			printf "${bold}[*]${reset} Successfully removed PVE Kernel Cleaner from the system!\n"
			printf "${bold}[-]${reset} Sorry to see you go :(\n"
		else
			printf "\nExiting...\nThat was a close one ⎦˚◡˚⎣\n"
		fi
		exit 0
	else
		# Tell the user that it is not installed
		printf "${bold}[!]${reset} This program is not installed on the system.\n"
		exit 1
	fi
}

# PVE Kernel Clean main function
pve_kernel_clean() {
	# Find all kernel identifiers from valid installed kernel packages
	mapfile -t kernels < <(collect_sorted_kernel_ids)
	# List of kernels that will be removed (adds them as the script goes on)
	kernels_to_remove=()
	# Boot drive status
	boot_drive_status=$(get_drive_status ${boot_info[4]})
	# Show space used, status and free space available
	printf "${bold}[*]${reset} Boot disk space used is ${bold}${boot_drive_status}${reset} at ${boot_info[4]}%% capacity (${boot_info[3]} free)\n"
	# For each kernel identifier discovered from installed packages
	for kernel in "${kernels[@]}"
	do
		# Check if the kernel is already in the array
		if [[ " ${kernels_to_remove[@]} " =~ " $kernel " ]]; then
			continue  # Skip adding it again
		fi
		# Never remove running kernel (including signed/unsigned variant pair)
		if is_running_kernel_variant "$kernel"; then
			continue
		fi
		# Add kernels to removal list based on --remove-newer behavior
		if [ "$remove_newer" == "true" ]; then
			kernels_to_remove+=("$kernel")
		elif kernel_id_lt "$kernel" "$current_kernel"; then
			kernels_to_remove+=("$kernel")
		fi
	done
	# If keep_kernels is set we remove this number from the array to remove
	if [[ -n "$keep_kernels" ]] && [[ "$keep_kernels" =~ ^[0-9]+$ ]]; then
		if [ $keep_kernels -gt 0 ]; then
			printf "${bold}[*]${reset} The last ${bold}$keep_kernels${reset} kernel$([ "$keep_kernels" -eq 1 ] || echo 's') will be held back from being removed.\n"
			# Check if the number of kernels to keep is greater than or equal to the number of kernels in the array
			if [ "$keep_kernels" -ge "${#kernels_to_remove[@]}" ]; then
				# Set keep_kernels to the number of kernels in the array
				keep_kernels="${#kernels_to_remove[@]}"
			fi			
			kernels_to_keep=("${kernels_to_remove[@]:${#kernels_to_remove[@]}-$keep_kernels:$keep_kernels}")
			kernels_to_remove=("${kernels_to_remove[@]::${#kernels_to_remove[@]}-$keep_kernels}")
		fi
	fi
	# Show kernels to be removed
	printf "${bold}[-]${reset} Searching for old PVE kernels on your system...\n"
	for kernel in "${kernels_to_remove[@]}"
	do
		printf "  ${bold}${green}+${reset} \"$kernel\" added to the kernel remove list\n"
	done
	for kernel in "${kernels_to_keep[@]}"
	do
		printf "  ${bold}${red}-${reset} \"$kernel\" is being held back from removal\n"
	done
	printf "${bold}[-]${reset} PVE kernel search complete!\n"
	# If there are no kernels to be removed then exit
	if [ ${#kernels_to_remove[@]} -eq 0 ]; then
		printf "${bold}[!]${reset} It appears there are no old PVE kernels on your system ⎦˚◡˚⎣\n"
		printf "${bold}[-]${reset} Good bye!\n"
	# Kernels found in removal list
	else
		num_to_remove=${#kernels_to_remove[@]}
		# Check if force removal was passed
		if [ $force_purge == true ]; then
			REPLY="y"
		# Ask the user if they want to remove the selected kernels found
		else
			printf "${bold}[!]${reset} Would you like to remove the ${bold}$num_to_remove${reset} selected PVE kernel$([ "$num_to_remove" -eq 1 ] || echo 's') listed above? [y/N]: " 
			read -n 1 -r
			printf "\n"
		fi
		# User wishes to remove the kernels
		if [[ $REPLY =~ ^[Yy]$ ]]; then
			printf "${bold}[*]${reset} Removing $num_to_remove old PVE kernel$([ "$num_to_remove" -eq 1 ] || echo 's')...\n"
			for kernel in "${kernels_to_remove[@]}"
			do
				printf "${bold}[-]${reset} Removing kernel: $kernel..."
				# Purge the old kernels via apt and suppress output
				if [ "$dry_run" != "true" ]; then
					mapfile -t packages_to_purge < <(collect_packages_for_kernel_id "$kernel")
					for package_name in "${packages_to_purge[@]}"; do
						/usr/bin/apt purge -y "$package_name" > /dev/null 2>&1
					done
				fi
				sleep 1			
				printf "${bold}${green}DONE!${reset}\n"
			done
			printf "${bold}[*]${reset} Updating GRUB..."
			# Update grub after kernels are removed, suppress output
			if [ "$dry_run" != "true" ]; then
				/usr/sbin/update-grub > /dev/null 2>&1
			fi
			printf "${bold}${green}DONE!${reset}\n"
			# Get information about the /boot folder
			boot_info=($(echo $(df -Ph | grep /boot | tail -1) | sed 's/%//g'))
			# Show information about the /boot
			printf "${bold}[-]${reset} ${bold}Boot Disk:${reset} ${boot_info[4]}%% full [${boot_info[2]}/${boot_info[1]} used, ${boot_info[3]} free] \n"
			# Script finished successfully
			printf "${bold}[-]${reset} Have a nice $(timeGreeting) ⎦˚◡˚⎣\n"
		# User wishes to not remove the kernels above, exit
		else
			printf "\nExiting...\n"
			printf "See you later ⎦˚◡˚⎣\n"
		fi
	fi
	exit 0
}

# Function to check for updates
check_for_update() {
	if [ "${PVEKCLEAN_SKIP_UPDATE_CHECK:-false}" == "true" ]; then
		return
	fi
	if [ "$check_for_updates" == "true" ] && [ "$force_purge" == "false" ]; then
		# Get latest version number
		local remote_version=$(curl -s -m 10 https://raw.githubusercontent.com/jordanhillis/pvekclean/master/version.txt | tr -d '\n' || echo "")
		# Unable to fetch remote version, so just skip the update check
		if [ -z "$remote_version" ]; then
			printf "${bold}[*]${reset} Failed to check for updates. Skipping update check.\n"
			return
		fi
		# Validate the remote_version format using a regex
		if [[ ! "$remote_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
			printf "${bold}[*]${reset} Invalid remote version format: ${bold}${orange}$remote_version${reset}. Skipping update check.\n"
			return
		fi
		# If version isn't the same
		if [ "$remote_version" != "$version" ]; then
			printf "*** A new version $remote_version is available! ***\n"
			printf "${bold}[*]${reset} Do you want to update? [y/N] "
			read -n 1 -r
			printf "\n"
			if [[ $REPLY =~ ^[Yy]$ ]]; then
				local updated_script=$(curl -s -m 10 https://raw.githubusercontent.com/jordanhillis/pvekclean/master/pvekclean.sh)
				# Check if the updated script contains the shebang line
				if [[ "$updated_script" == "#!/bin/bash"* ]]; then
					echo "$updated_script" > "$0"  # Overwrite the current script
					printf "${bold}[*]${reset} Successfully updated to version $remote_version\n"
					exec "$0" "$@"
				else
					printf "${bold}[*]${reset} The updated script does not contain the expected shebang line.\n"
					printf "${bold}[*]${reset} Update aborted!\n"
				fi
			fi
		fi
	fi
}

timeGreeting() {
    h=$(date +%k)  # Use %k to get the hour as a decimal number (no leading zero)
    ((h >= 5 && h < 12)) && echo "morning" && return
    ((h >= 12 && h < 17)) && echo "afternoon" && return
    ((h >= 17 && h < 21)) && echo "evening" && return
    echo "night"
}

main() {
	# Check for root
	check_root
	# Show header information
	header_info
	# Script usage
	show_usage
	# Show kernel information
	kernel_info
	# Check for updates
	check_for_update
	# Install program to /usr/local/sbin/
	install_program
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-i|--install )
			force_pvekclean_install=true
			main
			install_program
		;;
		-r|--remove )
			main
			uninstall_program
		;;
		-s|--scheduler)
			main
			scheduler
		;;
		-v|--version)
			version
		;;
		-h|--help)
			main
			exit 0
		;;
		-k|--keep)
			if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then
                keep_kernels="$2"
                shift 2
				continue
            else
                echo -e "${bold}Error:${reset} --keep/-k requires a number argument."
                exit 1
            fi
		;;
		-f|--force)
			force_purge=true
			shift
			continue
		;;
		-rn|--remove-newer)
			remove_newer=true
			shift
			continue
		;;	
		-d|--dry-run)
			dry_run=true
			shift
			continue
		;;				
		*)
			echo -e "${bold}Unknown option:${reset} $1"
			exit 1
		;;
    esac
    shift
done

main
pve_kernel_clean
