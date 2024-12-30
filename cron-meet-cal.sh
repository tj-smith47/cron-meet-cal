#!/usr/bin/env bash
# shellcheck disable=SC2010,SC2063,SC2094,SC2155
#
# CronMeetCal - Autogenerate ephemeral Crontab entries that open Zoom meetings from Google Calendar.
#
# About
# This script reads the current day's Google Calendar events, and adds entries to a user's crontab
# that automatically open Zoom meetings at the scheduled time. It logs daily events to a file, and
# can also integrate with nowplaying-cli (`brew install nowplaying-cli`) to ensure active music is
# paused prior to opening your meeting, regardless of its' source. It can optionally be configured
# to back up one week of pre & post script crontab file contents as an audit log.
#
# Setup
# 1. Install gcalcli: `brew install gcalcli`
# 2. Obtian an Oauth Client ID & Secret from Google Developer Console with read scopes for Google Calendar API
# 3. Run `gcalcli --client-id=[oath-client-id] init` to initialize & follow the prompts to login
# 4. Download this script to somewhere in your `PATH` and make it executable:
#     $ curl -sSL https://raw.githubusercontent.com/tjsmith/master/cron-meet-cal.sh -o ~/.local/bin/cron-meet-cal
#     $ chmod +x ~/.local/bin/cron-meet-cal
# 5. Prepend your crontab with a daily entry that runs this script:
#     $ echo -e "@daily\t[optional: any env overrides below] /path/to/cron-meet-cal\n$(crontab -l)" | crontab -
#
# NOTE: You may have to give your terminal emulator Full Disk Access in Settings if you're prompted in step 5.
#
# ENV's
# It can be configured with the following envs:
#  - CMC_BACKUP_DIR: Directory to store crontab backups (default: /tmp/cmc)
#  - CMC_ENABLE_BACKUP: Enable crontab backups (default: true)
#  - CMC_ENABLE_DEBUG: Enable debug logging (default: true)
#  - CMC_LOG_FILE: File to log events (default: ${CMC_BACKUP_DIR}/events.log)
#  - CMC_LOG_LIMIT: Max lines to keep in log file (default: 100)
#  - CMC_OFFSET_MIN: Minutes prior to start of meeting to open Zoom (default: 1)

## Environment Prep
# User vars
CMC_BACKUP_DIR=${CMC_BACKUP_DIR:-/tmp/cmc}
CMC_ENABLE_BACKUP=${CMC_ENABLE_BACKUP:-true}
CMC_ENABLE_DEBUG=${CMC_ENABLE_DEBUG:-true}
CMC_LOG_FILE=${CMC_LOG_FILE:-${CMC_BACKUP_DIR}/events.log}
CMC_LOG_LIMIT=${CMC_LOG_LIMIT:-100}
CMC_OFFSET_MIN=${CMC_OFFSET_MIN:-1}

# Meeting & crontab vars
TODAY=$(date "+%Y-%m-%d")
DOW=$(date +'%A' | tr '[:upper:]' '[:lower:]')
CT_CONTENT=$(crontab -l)
AGENDA=$(
  gcalclz agenda --details location --details conference --military --tsv 2>/dev/null |
    grep -v Home | grep "${TODAY}"
)

## Functions
add_new_meeting_entries() {
  # Parse local Zoom info
  zoom_app=$(ls -h1 /Applications | grep -m 1 zoom)
  zoom_bin=$(echo "${zoom_app}" | cut -d'.' -f1,2)
  zoom_path="/Applications/${zoom_app}/Contents/MacOS/${zoom_bin}"
  [[ ! -f "${zoom_path}" ]] && log_event "ERROR: Zoom app not found at ${zoom_path}"

  # Set command prefix
  cmd_prefix="/usr/bin/open -a ${zoom_path}"
  if [[ -f "$(brew --prefix)/bin/nowplaying-cli" ]]; then
    # Optionally pause music before opening the meeting
    cmd_prefix="$(brew --prefix)/bin/nowplaying-cli pause 2>/dev/null; ${cmd_prefix}"
  fi

  # Add anchor point comment
  if ! grep -q 'Managed by CronMeetCal' <<<"${CT_CONTENT}"; then
    CT_CONTENT+="\n\n########## Managed by CronMeetCal ##########"
  fi

  # Add new entries from gcalcli agenda
  while read -r line; do
    # Skip lines without a meeting link
    if ! grep 'zoom' <<<"${line}"; then
      [[ "${CMC_ENABLE_DEBUG}" == "true" && -n "${line}" ]] && log_event "Skipping line: ${line}"
      continue
    fi

    # Generate cron time elements (optionally set offset for opening app)
    meeting_time=$(echo "${line}" | awk '{print $2}')
    if [[ "${CMC_OFFSET_MIN:-1}" != "0" ]]; then
      date_obj=$(date -j -f '%H:%M' "${meeting_time}" +'%s')
      offset_min=$((CMC_OFFSET_MIN * 60))
      meeting_time=$(date -j -r "$((date_obj - offset_min))" +'%H:%M')
    fi
    hour=$(echo "${meeting_time}" | cut -d':' -f1)
    minute=$(echo "${meeting_time}" | cut -d':' -f2)

    # Parse meeting info
    meeting_link=$(echo -e "${line}" | sed 's/\t/\n/g' | grep -m 1 'zoom')
    meeting_title=$(echo -e "${line}" | sed 's/\t/\n/g' | grep -v -E "^..:..$|^video$|https|${TODAY}" -m 1)

    # Generate cron entry
    comment="# Open meeting: ${meeting_title} | ${TODAY} @${hour}:${minute}"
    entry="${minute} ${hour} * * $(date +%u) ${cmd_prefix} ${meeting_link}"

    # Append new entry to crontab content
    CT_CONTENT="${CT_CONTENT}\n${comment}\n${entry}"
  done <<<"${AGENDA}"

  echo -e "${CT_CONTENT}" | crontab -
}

cleanup() {
  # Trim log file
  cat <<<"$(tail -n "${CMC_LOG_LIMIT}" "${CMC_LOG_FILE}")" >"${CMC_LOG_FILE}"

  # Backup 'after' crontab if requested
  if [[ "${CMC_ENABLE_BACKUP}" == "true" ]]; then
    crontab -l >"${CMC_BACKUP_DIR}/${DOW}/crontab.new"
  fi
}

ensure_deps() {
  # Check for gcalcli
  if ! command -v gcalcli &>/dev/null; then
    log_event "ERROR: gcalcli is not installed. Run \`brew install gcalcli\`, initialize, and try again" >&2
  fi

  # Check for homebrew
  if ! command -v brew &>/dev/null; then
    log_event "ERROR: Homebrew is not installed. Install it and try again" >&2
  fi
}

log_event() {
  echo "${TODAY} - ${1}" >>"${CMC_LOG_FILE}"
  grep -q 'ERROR' <<<"${1}" && exit 1
}

remove_previous_entries() {
  local tmp_file="$(mktemp)"

  while read -r line; do
    echo -e "${line}" >>"${tmp_file}"
    if grep -q 'Managed by CronMeetCal' "${tmp_file}"; then
      # Stop when we reach the anchor point
      break
    fi
  done <<<"${CT_CONTENT}"

  CT_CONTENT=$(cat "${tmp_file}")
  rm "${tmp_file}"
}

setup_environment() {
  # Create log file subdirectory if it doesn't exist
  if [[ ! -f "${CMC_LOG_FILE}" ]]; then
    log_dir=$(dirname "${CMC_LOG_FILE}")
    [[ ! -d "${log_dir}" ]] && mkdir -p "${log_dir}"
    log_event "Creating log file at ${CMC_LOG_FILE}"
  fi

  # Backup 'before' crontab if requested
  if [[ "${CMC_ENABLE_BACKUP}" == "true" ]]; then
    dow_backup_dir="${CMC_BACKUP_DIR}/${DOW}/"
    [[ ! -d "${dow_backup_dir}" ]] && {
      log_event "Creating backup dir for ${DOW}"
      mkdir -p "${dow_backup_dir}"
    }
    crontab -l >"${dow_backup_dir}/crontab.bak"
  fi

  # Remove previous entries if they exist
  if grep -q 'Managed by CronMeetCal' <<<"${CT_CONTENT}"; then
    log_event "Removing previous entries"
    remove_previous_entries
  fi
}

## MAIN ##
setup_environment
ensure_deps

# Determine necessary behavior from agenda contents
HOLIDAY=$(grep -q 'Holiday' <<<"${AGENDA}" && echo "true" || echo "false")
NUM_MEETINGS=$(echo -e "${AGENDA}" | grep 'zoom' | grep -c -)
OUT_OF_OFFICE=$(grep -q -i 'ooo\|out of office' <<<"${AGENDA}" && echo "true" || echo "false")

if [[ -z "${AGENDA}" ]] || [[ "${NUM_MEETINGS}" == "0" ]]; then
  log_event "No meetings detected, removed previous entries"
elif [[ "${OUT_OF_OFFICE}" == "true" ]]; then
  log_event "OOO detected, removed previous entries"
elif [[ "${HOLIDAY}" == "true" ]]; then
  log_event "Holiday detected, removed previous entries"
else
  log_event "${NUM_MEETINGS} Zoom meetings detected, updating crontab"
  add_new_meeting_entries
fi

cleanup
