<h1 align="center">
  CronMeetCal
</h1>

<h3 align="center">
  (Cron)tab Scheduling · Zoom (Meet)ings · Google (Cal)endar
</h3>

Crontab, meet calendar; schedule cron jobs that auto-join Zoom meetings found in your Google Calendar.

## What does CronMeetCal do?

Each day, this script checks your scheduled meetings in Google Calendar, then appends entries to your
crontab that will automatically join those with Zoom meetings at the scheduled time. It will also clean
the previous day's meetings daily, and skips adding entries if any holiday or out of office events are
detected on your calendar.

### Dependencies

- [`gcalcli`](https://github.com/insanum/gcalcli) - A command line interface for the Google Calendar API (requires an Oauth Client ID & Secret)
- [`nowplaying-cli`](https://github.com/kirtan-shah/nowplaying-cli) - Optional: A command line interface for controlling music playback from any source

### Additional Features

- Maintains a daily event log file of a user-configurable length (default 100 lines).
- Integrates with `nowplaying-cli` to ensure active music is paused prior to opening your meeting.
- Can optionally be configured to back up one week of pre & post script crontab files.

## Setup

1. Install dependencies:

```bash
brew install gcalcli

# Optional: install nowplaying-cli to pause music
brew install nowplaying-cli
```

2. Obtian an Oauth Client ID & Secret from Google Developer Console w/ read scopes for Google Calendar API

3. Run the following to initialize `gcalcli`, then follow the prompts to login:

```bash
gcalcli --client-id=[oath-client-id] init
```

4. Download this script to somewhere in your `$PATH` and make it executable:

```bash
curl -sSL https://raw.githubusercontent.com/tjsmith/cron-meet-cal/master/cron-meet-cal.sh -o ~/.local/bin/cron-meet-cal
chmod +x ~/.local/bin/cron-meet-cal
```

5. Prepend your crontab with a daily entry that runs this script:

```bash
echo -e "@daily\t[optional: desired envs] /path/to/cron-meet-cal\n$(crontab -l)" | crontab -
```

### Permissions

You may get a confirmation popup when running step 5 about elevated permissions. If so, you'll
need to allow your terminal editor full disk access in Settings in order to let this script update
your crontab unattended. To do so, go to `Settings > Privacy & Security > Full Disk Access`, then
allow your terminal application access.
> This is due to a new MacOS Sonoma setting, but is generally safe - many common apps for Mac (like Alfred) require this setting as well. Even enabled, user specific permissions will still limit file access per user.

## ENV's

CronMeetCal can be configured if desired with the following envs:
| Env | Description | Default |
| --- | ----------- | ------- |
| CMC_BACKUP_DIR | Directory to store crontab backups | `/tmp/cmc` |
| CMC_ENABLE_BACKUP | Enable crontab backups | `true` |
| CMC_ENABLE_DEBUG | Enable debug logging | `true` |
| CMC_LOG_FILE | File to log events | `${CMC_BACKUP_DIR}/events.log` |
| CMC_LOG_LIMIT | Max lines to keep in log file | `100` |
| CMC_OFFSET_MIN | # min prior to meeting start to open Zoom | `1` |
