#!/usr/bin/env bash
#
# Incremental Discord server backup driver (Linux / macOS / Docker).
#
# First run for a guild   -> full history export.
# Every run after that    -> only messages newer than the last successful run
#                            (via DiscordChatExporter's --after option).
#
# Output is written as a folder tree:  <outputRoot>/<Server>/<Category>/<Channel>/...
# Each run is timestamped so nothing is ever overwritten.
#
# Config is read from JSON (see config.example.json). Env vars override config:
#   DCE_TOKEN, DCE_CLI, DCE_CONFIG, DCE_OUTPUT_ROOT, DCE_STATE_DIR, DCE_LOG_DIR
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="${DCE_CONFIG:-$BACKUP_DIR/config.json}"
STATE_DIR="${DCE_STATE_DIR:-$BACKUP_DIR/state}"
LOG_DIR="${DCE_LOG_DIR:-$BACKUP_DIR/logs}"
STATE_FILE="$STATE_DIR/state.json"
# Inside Docker the CLI lives at /opt/app; on a host it's usually on PATH or set via DCE_CLI.
DCE_CLI="${DCE_CLI:-DiscordChatExporter.Cli}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: 'jq' is required (apt install jq / brew install jq)." >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "ERROR: config not found at $CONFIG" >&2; exit 1; }

mkdir -p "$STATE_DIR" "$LOG_DIR"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

TOKEN="${DCE_TOKEN:-$(jq -r '.token // ""' "$CONFIG")}"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "ERROR: no token (set DCE_TOKEN env or .token in config)." >&2; exit 1; }

OUTPUT_ROOT="${DCE_OUTPUT_ROOT:-$(jq -r '.outputRoot // "./exports"' "$CONFIG")}"
FORMAT="$(jq -r '.format // "Json"' "$CONFIG")"
MEDIA="$(jq -r '.downloadMedia // true' "$CONFIG")"
THREADS="$(jq -r '.includeThreads // "all"' "$CONFIG")"
VC="$(jq -r '.includeVoice // true' "$CONFIG")"
# Throttle: minimum ms between requests, to avoid tripping Discord's ban heuristics.
# Env var wins over config; 0 (or absent) disables the throttle.
REQUEST_DELAY="${DCE_REQUEST_DELAY:-$(jq -r '.requestDelayMs // 0' "$CONFIG")}"
[ "$REQUEST_DELAY" = "null" ] && REQUEST_DELAY=0

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"

case "$FORMAT" in
  Json)               EXT=json ;;
  HtmlDark|HtmlLight) EXT=html ;;
  PlainText)          EXT=txt  ;;
  Csv)                EXT=csv  ;;
  *)                  EXT=dat  ;;
esac

RUN_STAMP="$(date -u +%Y-%m-%d_%H%M%S)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOG="$LOG_DIR/backup-$RUN_STAMP.log"

mapfile -t GUILDS < <(jq -r '.guilds[]?' "$CONFIG")
[ "${#GUILDS[@]}" -gt 0 ] || { echo "ERROR: config.guilds is empty." >&2; exit 1; }

echo "=== DiscordChatExporter incremental backup ===" | tee -a "$LOG"
echo "run: $RUN_STAMP   format: $FORMAT   guilds: ${#GUILDS[@]}   output: $OUTPUT_ROOT" | tee -a "$LOG"

overall_rc=0
for GUILD in "${GUILDS[@]}"; do
  LAST="$(jq -r --arg g "$GUILD" '.[$g] // ""' "$STATE_FILE")"
  [ "$LAST" = "null" ] && LAST=""
  echo "==> Guild $GUILD  (since: ${LAST:-FULL HISTORY})" | tee -a "$LOG"

  args=( exportguild -t "$TOKEN" -g "$GUILD" -f "$FORMAT"
         -o "$OUTPUT_ROOT/%G/%T/%C/%C_${RUN_STAMP}.${EXT}"
         --include-threads "$THREADS" --include-vc "$VC"
         --fuck-russia )
  if [ "$MEDIA" = "true" ]; then
    args+=( --media --reuse-media --media-dir "$OUTPUT_ROOT/_media/guild-$GUILD/" )
  fi
  [ "$REQUEST_DELAY" != "0" ] && args+=( --request-delay "$REQUEST_DELAY" )
  [ -n "$LAST" ] && args+=( --after "$LAST" )

  if "$DCE_CLI" "${args[@]}" 2>&1 | tee -a "$LOG"; then
    tmp="$(mktemp)"
    jq --arg g "$GUILD" --arg t "$NOW_ISO" '.[$g]=$t' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    echo "    OK — state advanced to $NOW_ISO" | tee -a "$LOG"
  else
    echo "    ERROR exporting guild $GUILD (state NOT advanced; will retry next run)" | tee -a "$LOG" >&2
    overall_rc=1
  fi
done

REMOTE_ENABLED="$(jq -r '.remote.enabled // false' "$CONFIG")"
if [ "$REMOTE_ENABLED" = "true" ]; then
  RCLONE_REMOTE="$(jq -r '.remote.rcloneRemote // ""' "$CONFIG")"
  if command -v rclone >/dev/null 2>&1 && [ -n "$RCLONE_REMOTE" ] && [ "$RCLONE_REMOTE" != "null" ]; then
    echo "==> Syncing to remote: $RCLONE_REMOTE" | tee -a "$LOG"
    rclone copy "$OUTPUT_ROOT" "$RCLONE_REMOTE" 2>&1 | tee -a "$LOG" || overall_rc=1
  else
    echo "WARN: remote.enabled=true but rclone missing or remote unset." | tee -a "$LOG" >&2
  fi
fi

echo "=== done (exit $overall_rc) ===" | tee -a "$LOG"
exit $overall_rc
