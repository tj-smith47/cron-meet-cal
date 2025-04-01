#!/usr/bin/env bash
# shellcheck disable=SC2001,SC2010,SC2046,SC2063,SC2094,SC2155
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
#     $ curl -sSL https://raw.githubusercontent.com/tj-smith47/cron-meet-cal/refs/heads/master/cron-meet-cal.sh -o ~/.local/bin/cron-meet-cal
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
CMC_TESTING="${CMC_TESTING:-false}"

# Meeting & crontab vars
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}" # Ensure brew is in path
MINUTE=$(date +'%M')
HOUR=$(date +'%-H')
DATE=$(date +"%Y-%m-%d")
TMRW=$(date -v+1d +"%Y-%m-%d")
DOW=$(date +'%A' | tr '[:upper:]' '[:lower:]')
CT_CONTENT=$(crontab -l)
AGENDA=$(
  gcalcli agenda --details time --details location --details conference --military --tsv "${DATE}" "${TMRW}" 2>/dev/null |
    grep -vE 'start_date|Home|Office Hours with'
)
[[ "${CMC_TESTING}" == "true" ]] && echo -e "AGENDA:\n${AGENDA}\n"

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
    if ! grep -q 'zoom' <<<"${line}"; then
      [[ "${CMC_ENABLE_DEBUG}" == "true" && -n "${line}" ]] &&
        log_event "Skipping line: ${line}"
      continue
    fi

    # Parse meeting info
    meeting_link=$(echo -e "${line}" | sed 's/\t/\n/g' | grep -m 1 'zoom')
    meeting_title=$(echo -e "${line}" | sed 's/\t/\n/g' | grep -v -E "^..:..$|^video$|https|${DATE}" | grep -m 1 .)
    meeting_time=$(echo "${line}" | awk '{print $2}')

    # Parse cron time elements (check optional offset for opening app)
    if [[ "${CMC_OFFSET_MIN:-1}" != "0" ]]; then
      date_obj=$(date -j -f '%H:%M' "${meeting_time}" +'%s')
      offset_min=$((CMC_OFFSET_MIN * 60))
      meeting_time=$(date -j -r "$((date_obj - offset_min))" +'%H:%M')
    fi
    hour=$(echo "${meeting_time}" | cut -d':' -f1)
    minute=$(echo "${meeting_time}" | cut -d':' -f2)

    # Skip if meeting is in the past
    meeting_is_future "${hour}" "${minute}" || continue

    # Generate cron entry
    comment="# Open meeting: ${meeting_title} | ${DATE} @${hour}:${minute}"
    entry="${minute} ${hour} * * $(date +%u) ${cmd_prefix} ${meeting_link}"

    # Append new entry to crontab content
    CT_CONTENT="${CT_CONTENT}\n${comment}\n${entry}\n"
  done < <(grep "${DATE}" <<<"${AGENDA}")

  echo -e "${CT_CONTENT}" | crontab -
}

begin_setup() {
  # Create log file subdirectory if it doesn't exist
  if [[ ! -f "${CMC_LOG_FILE}" ]]; then
    log_dir=$(dirname "${CMC_LOG_FILE}")
    [[ ! -d "${log_dir}" ]] && mkdir -p "${log_dir}"
    [[ "${CMC_ENABLE_DEBUG}" == "true" ]] &&
      log_event "Creating log file at ${CMC_LOG_FILE}"
  fi

  # Backup 'before' crontab if requested
  if [[ "${CMC_ENABLE_BACKUP}" == "true" ]]; then
    # Determine backup directory from frequency
    backup_dir=$(get_backup_dir)

    # Create backup directory if it doesn't exist
    [[ ! -d "${backup_dir}" ]] && {
      [[ "${CMC_ENABLE_DEBUG}" == "true" ]] &&
        log_event "Creating backup dir for ${DOW}$(grep -q "${HOUR}" <<<"${backup_dir}" && echo -e "/${HOUR}")"
      mkdir -p "${backup_dir}"
    }

    # Backup current crontab
    crontab -l >"${backup_dir}/crontab.bak"
  fi

  # Remove previous entries if they exist
  if grep -q 'Managed by CronMeetCal' <<<"${CT_CONTENT}"; then
    [[ "${CMC_ENABLE_DEBUG}" == "true" ]] &&
      log_event "Removing previous entries"
    remove_previous_entries
  fi
}

check_cron_frequency() {
  # Determine cron frequency
  if grep 'cron-meet-cal' <<<"${CT_CONTENT}" | grep -q 'daily'; then
    echo "daily"
  else
    echo "hourly"
  fi
}

ensure_dependencies() {
  if [[ -z "${AGENDA}" ]]; then
    # Check for homebrew
    if ! command -v brew &>/dev/null; then
      log_event "ERROR: Homebrew is not installed. Install it and try again" >&2
    fi

    # Check for gcalcli
    if ! command -v gcalcli &>/dev/null; then
      log_event "ERROR: gcalcli is not installed. Run \`brew install gcalcli\`, initialize, and try again" >&2
    fi
  fi
}

get_backup_dir() {
  backup_dir="${CMC_BACKUP_DIR}/${DOW}/"
  [[ "$(check_cron_frequency)" == "hourly" ]] && backup_dir+="${HOUR}/"
  echo "${backup_dir}"
}

get_country() {
  local country_code=$(locale | grep -m 1 'UTF' | cut -d '_' -f 2 | cut -d '.' -f 1)
  case "${country_code}" in
  "US")
    echo "United States|US"
    ;;
  "GB")
    echo "London|UK"
    ;;
  "PL")
    echo "Poland|Warsaw"
    ;;
  "MX")
    echo "Mexico|MX"
    ;;
  *)
    country_name=$(curl -sL http://whatismycountry.com/ | grep -m 1 'Your country is' | sed 's/.*country">Your country is \(.*\) ..<.*/\1/g')
    [[ -n "${country_name}" ]] && echo "${country_name}|${country_code}" || echo "${country_code}"
    ;;
  esac
}

get_holiday_cal() {
  local holiday_cals=$(gcalcli list | grep 'Holiday' | sed 's/.*  \(.*\)/\1/g')
  if [[ $(grep -c 'Holidays' <<<"${holiday_cals}") -gt 1 ]]; then
    echo "${holiday_cals}" | grep -m 1 -E "$(get_country)"
  else
    echo "${holiday_cals}"
  fi
}

get_is_holiday() {
  local holiday_agenda=$(
    gcalcli agenda --calendar "$(get_holiday_cal)" --details time --military --tsv "${DATE}" 2>/dev/null
  )
  local is_holiday=false

  if [[ -n "${holiday_agenda}" ]]; then
    holiday_name=$(sed 's/\t/\n/g' <<<"${holiday_agenda}" | grep . | tail -n 1)
    # Real holidays will be in the user's normal calendar, and include start / end times
    grep "${holiday_name}" <<<"${AGENDA}" | sed 's/\t/\n/g' | grep -q '^..:..$' && {
      log_event "Holiday detected: ${holiday_name}"
      is_holiday=true
    }
  fi

  echo "${is_holiday}"
}

log_event() {
  echo "[${DATE} $(date +'%H:%M:%S')] - ${1}" >>"${CMC_LOG_FILE}"
  [[ "${CMC_TESTING}" == "true" ]] && echo "${1}"
  grep -q 'ERROR' <<<"${1}" && exit 1
}

meeting_is_future() {
  local current_hour=$(sed 's/^0//' <<<"${HOUR}")
  local meeting_hour=$(sed 's/^0//' <<<"${1}")
  local current_minute=$(sed 's/^0//' <<<"${MINUTE}")
  local meeting_minute=$(sed 's/^0//' <<<"${2}")

  if [[ "${current_hour}" -gt "${meeting_hour}" ]]; then
    return 1
  elif [[ "${current_hour}" -eq "${meeting_hour}" && "${current_minute}" -gt "${meeting_minute}" ]]; then
    return 1
  fi
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
  crontab "${tmp_file}"
  rm "${tmp_file}"
}

update_crontab() {
  # Determine necessary behavior from agenda contents
  COUNT_OF_MEETINGS=$(echo -e "${AGENDA}" | grep 'zoom' | grep -c -)
  OUT_OF_OFFICE=$(grep -q -i 'ooo\|out of office' <<<"${AGENDA}" && echo "true" || echo "false")
  HOLIDAY=$(get_is_holiday)

  if [[ "${CMC_TESTING}" == "true" ]]; then
    echo -e "Agenda:\n${AGENDA}\n"
    echo "Out of Office: ${OUT_OF_OFFICE}"
    echo "Holiday: ${HOLIDAY}"
  fi

  if [[ "${OUT_OF_OFFICE}" == "true" ]]; then
    log_event "OOO detected, skipping update"
  elif [[ "${HOLIDAY}" == "true" ]]; then
    log_event "Holiday detected, skipping update"
  elif [[ -z "${AGENDA}" ]] || [[ "${COUNT_OF_MEETINGS}" == "0" ]]; then
    log_event "No meetings detected, nothing to add"
  else
    context=$(grep -q '1' <<<"${COUNT_OF_MEETINGS}" && echo "meeting" || echo "meetings")
    log_event "${COUNT_OF_MEETINGS} Zoom ${context} detected, updating crontab"
    add_new_meeting_entries
  fi
}

wrap_up() {
  # Trim log file
  cat <<<"$(tail -n "${CMC_LOG_LIMIT}" "${CMC_LOG_FILE}")" >"${CMC_LOG_FILE}"

  # Backup 'after' crontab if requested...
  if [[ "${CMC_ENABLE_BACKUP}" == "true" ]]; then
    backup_dir=$(get_backup_dir)
    crontab -l >"${backup_dir}/crontab.new"
    # ...but remove backup subdir for this hour's run if not changed
    if cmp -s "${backup_dir}/crontab.bak" "${backup_dir}/crontab.new"; then
      rm -rf "${backup_dir}"
    fi
  fi
}

## MAIN ##
begin_setup
ensure_dependencies
update_crontab
wrap_up
