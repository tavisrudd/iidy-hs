#!/usr/bin/env bash
set -euo pipefail

LOGFILE="$(dirname "$0")/progress.log"
NTFY_URL="ntfy.sh/tavis-iidy-port-2026"
SENT_FILE="/tmp/watch-progress-sent.log"

notify() {
  curl -s -H "Priority: high" -H "Tags: wrench" -d "$1" "$NTFY_URL" >/dev/null
}

touch "$SENT_FILE"

# Send last line on start if not already sent
if [[ -f "$LOGFILE" ]]; then
  last=$(tail -n1 "$LOGFILE")
  if [[ -n "$last" ]] && ! grep -qFx "$last" "$SENT_FILE"; then
    notify "$last"
    echo "$last" >> "$SENT_FILE"
  fi
fi

# Tail and notify only unseen lines
tail -n0 -F "$LOGFILE" | while IFS= read -r line; do
  if [[ -n "$line" ]] && ! grep -qFx "$line" "$SENT_FILE"; then
    notify "$line"
    echo "$line" >> "$SENT_FILE"
  fi
done
