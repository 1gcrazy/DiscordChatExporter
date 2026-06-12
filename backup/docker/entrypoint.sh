#!/usr/bin/env bash
#
# Container entrypoint: optionally run an immediate backup, then hand off to cron
# so the backup repeats on CRON_SCHEDULE forever.
#
set -e

echo "=================================================="
echo " DiscordChatExporter scheduled backup"
echo " schedule : ${CRON_SCHEDULE}"
echo " output   : ${DCE_OUTPUT_ROOT}"
echo " timezone : ${TZ}"
echo "=================================================="

mkdir -p "$DCE_OUTPUT_ROOT" "$DCE_STATE_DIR" "$DCE_LOG_DIR"

if [ ! -f "$DCE_CONFIG" ]; then
  echo "ERROR: config not found at $DCE_CONFIG — mount it as a volume (see docker-compose.yml)." >&2
  exit 1
fi

# Run once immediately so the first backup doesn't wait for the first cron tick.
if [ "${RUN_ON_START:-true}" = "true" ]; then
  echo "RUN_ON_START=true -> running initial backup now..."
  /opt/backup/backup.sh || echo "WARN: initial backup returned non-zero (continuing to schedule)."
fi

# cron runs with a bare environment, so snapshot the vars the driver needs and
# source them at the top of the cron command.
CRON_ENV=/opt/backup/cron.env
printenv | grep -E '^(DCE_|TZ=)' > "$CRON_ENV" || true
# printenv quotes nothing; make the file safe to `source`
sed -i 's/^\([^=]*\)=\(.*\)$/export \1="\2"/' "$CRON_ENV"

echo "${CRON_SCHEDULE} . ${CRON_ENV}; /opt/backup/backup.sh >> ${DCE_LOG_DIR}/cron.log 2>&1" > /etc/crontabs/root
echo "Installed crontab:"
cat /etc/crontabs/root

echo "Starting cron (foreground)..."
exec crond -f -l 8
