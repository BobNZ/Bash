#!/usr/bin/env sh
# Turn on echo
# 	set -x 

echo "STARTED $(date +%Y.%m.%d_%H.%M)"

# Example Libraries https://github.com/ElectricRCAircraftGuy/eRCaGuy_hello_world/tree/master/bash
# Calling and testing libraries

DIR_LOG="/mnt/user/nas/Logs"
DIR_BACKUP="/mnt/user/nas/Backup/UnRaid"
DIR_APPDATA="/mnt/user/appdata"

DEFAULT_TOPIC=""
DEFAULT_OWNER=""
DEFAULT_LOGLEVEL="INFO"


################################
## Copy files
################################
function copy_files() {
	local copy_source="$1"
	local copy_dest="$2"
	local copy_type="$3" # SYNCH, ALL, BLANK i.e. last 14 days
	local log_name="$4"
	local log_level="${5:-$DEFAULT_LOGLEVEL}"

	
	# Update permissions so we can view the log file while it is processing
	touch "$log_name"
	chmod 777 "$log_name"

	case "$copy_type" in
	  "SYNCH")
		rsync  -rzvP "$copy_source" "$copy_dest" --log-file="$log_name" # --log-level="$log_level" --use-json-log
		;;
	  "ALL")
		rclone copy -P --update "$copy_source" "$copy_dest" --log-file="$log_name" --log-level="$log_level" --use-json-log
		;;
	  *)
		rclone copy -P --update --max-age 14d "$copy_source" "$copy_dest" --log-file="$log_name" --log-level="$log_level" --use-json-log
		;;
	esac
	
	# Check for any errors in processing
	checklog_errors "$log_name"
	# Purge the files in the log directory
	purge_dir "$DIR_LOG"
	
	echo "COPY COMPLETED $(date +%Y.%m.%d_%H.%M)"
	# https://stackoverflow.com/questions/8742783/returning-value-from-called-function-in-a-shell-script
	return $ret_val
}

################################
## Copy FTP files
################################
# Rclone copy issues
# 1. Cannot see folders with brackets
# 2. Does not copy the entire file list in a folder that has brackets i.e. even if you know the folder name you cannot use rclone copy <foldername>, however
# 3. Can copy individual files in folders with brackets, but the full path must be provide (with UNESCAPED brackets)
# 
# Rclone ls etc - 
# 1. Can see folders with brackets
# 2. Can only list files in folder with brackets BUT only if brackets are ESCAPED 
#
# Solution: Recursively steps through directories with Rclone ls (with ESCAPED brackets) and Rclone copy files in those directories with full path (UNESCAPED brackets)
function ftp_copy() {
	local ftp_source="$1"
	local ftp_dest="$2"
	local log_name="$3"
	local log_level="${4:-$DEFAULT_LOGLEVEL}"
	local ftp_current_dir="$5"
	
    # Escape brackets for rclone ls calls
    #escaped_dir=$(sed 's/\[/\\[/g' <<< "$ftp_current_dir")
    #escaped_dir=$(sed 's/\]/\\]/g' <<< "$escaped_dir")

    #rclone lsjson "$ftp_source/$escaped_dir" | jq -r '.[] | "\(.MimeType) \(.Path)"' | while read -r subfolder_type subfolder_path
    rclone lsjson "$ftp_source$ftp_current_dir" | jq -r '.[] | "\(.MimeType)\\\(.Path)"' | while  IFS='\' read -r subfolder_type subfolder_path
    do
        # recurse through folders
        if [[ $subfolder_type == 'inode/directory' ]] then
            ftp_copy "$ftp_source" "$ftp_dest" "$log_name" "$log_level" "$ftp_current_dir/$subfolder_path"
        else
            # Copy full path of all files
            local source_file="$ftp_source$ftp_current_dir/$subfolder_path"
            local dest_folder="$ftp_dest$ftp_current_dir"
            rclone --ignore-existing --one-file-system --transfers=8  --checkers=16 --stats 5m --bwlimit=10000 -P copy "$source_file" "$dest_folder" \
                    --log-file="$log_name" --log-level="$log_level" --use-json-log
        fi
    done
}

function checklog_errors() {
	local $log_name=#1
	
    # Check logfile for errors 
	local ret_val="0"
	jq -r '. | select(.msg | test("transferred";"i")) | .stats.errors' "$log_name" | while read -r errors
	  do
		echo $errors
		if [ "$errors" -ne "0" ]; then
			ret_val=1
			break
		fi
	done
	return $ret_val
}

#############################################
## Tar file to backup dir
#############################################
# Only tar if at least one file has changed in the last days
# or if it is Sunday
function tar_copy() {
	local backup_name="$1" 
	local source_dir="$2" # path to backup folder. Separated from tar_source so tar contents start at tar_source
	local tar_source="$3"
	local kuma_token="$4"
	local tar_exclude="$5"
	
	local tar_dest="${DIR_BACKUP}/${backup_name}"
	local tar_filename="${backup_name}_data_$(date +%Y.%m.%d_%H%M).tar.gz"
	local log_name="$DIR_LOG/Log_$(date +%Y.%m.%d.%H%M)_${backup_name}.log"
	
	[ -d "${tar_dest}" ] || mkdir "${tar_dest}"
	cd "${source_dir}"
	
	# https://stackoverflow.com/questions/21133070/check-if-directory-has-changed
	[[ $(date +%u) = 7 ]] && local fileFound=1 || local fileFound=$(find "${tar_source}" -type f -mtime -1 | head -n 1)
    if [[ $fileFound ]]; then
		tar -C "${tar_source}" -cvzf "${tar_dest}/${tar_filename}" -X <(for i in ${tar_exclude}; do echo $i; done) . 2>"$log_name" # Exludes are for backup of boot dir
	fi
	kuma_notification "${kuma_token}" "$?" # Register outcome with Uptime Kuma
	purge_dir "$backup_name"		
}
	

################################
## Kuma Notification
################################
# Report any errors found if a logfile to Kuma
function kuma_notification() {
	local kuma_token="$1"
	local kuma_result=$(( "$2" == 0 ? 0 : 1 )) # Ensure result is either success or failure
	
	# Kuma Details
	local kuma_URL="http://192.168.1.216:3001/api/push/"
	local kuma_message=("?ping&status=up&msg=OK" "?ping&status=down&msg=")

	echo "REPORTING $(date +%Y.%m.%d_%H.%M): curl ${kuma_URL}${kuma_token}${kuma_message[kuma_result]}"
	curl "${kuma_URL}${kuma_token}${kuma_message[kuma_result]}"
}


################################
## Ntfy Notification
################################
# Send notification to Ntfy
function ntfy_notification() {
	local ntfy_title="$1"           # https://docs.ntfy.sh/publish/#message-title
	local ntfy_message="$2" 
	local ntfy_topic="${5:-$DEFAULT_TOPIC}" 
	local ntfy_priority="${3:-3}"   # Default level https://docs.ntfy.sh/publish/#message-priority
	local ntfy_tags="$4"            # https://docs.ntfy.sh/publish/#tags-emojis
	
	echo "REPORTING $(date +%Y.%m.%d_%H.%M): curl -H Title:${ntfy_title} -H Priority:${ntfy_priority} -H Tags:${ntfy_tags} -d Message:${ntfy_message} ntfy.sh/${ntfy_topic}"	
	curl \
	  -H "Title: ${ntfy_title}" \
	  -H "Priority: ${ntfy_priority}" \
	  -H "Tags: ${ntfy_tags}" \
	  -d "${ntfy_message}" \
	  ntfy.sh/${ntfy_topic}
}


######################################
## Delete all files older than 14 days
######################################
#
function purge_dir() {
	local purge_dir="${1:-$DIR_LOG}"

	# if purge_dir does not contains "/" e.g. dokuwiki then it must be referring to
	# a Backup folder in $DIR_BACKUP
	#[[ $purge_dir =~ "/" ]] || purge_dir="${DIR_BACKUP}/${purge_dir}"	
	# Only allow purging of the Backup and Log Directory! 
	
	echo purge_dir "$purge_dir"
	if [[ "$purge_dir" = "$DIR_LOG" ]]; then
		# cleanup file over 14 days old	
		find ${purge_dir} -ctime +14 -delete
	else
		# purge all but the last 10 files
		# https://stackoverflow.com/questions/25785/delete-all-but-the-most-recent-x-files-in-bash
		purge_dir="${DIR_BACKUP}/${purge_dir}"   
		cd "$purge_dir"
		ls -tp | grep -v '/$' | tail -n +11 | tr '\n' '\0' | xargs -0 rm --
	fi
		
	# update the owner while we are here
	update_owner "$purge_dir"
}



######################################
## Update owner
######################################
#
function update_owner() {
	local update_dir="$1"
	local update_owner="${2:-$DEFAULT_OWNER}"
	
	# Update owner if a dir was provided
	[[ -n "${update_dir}" ]] && chown -R "${update_owner}" "${update_dir}" 
}

