#!/usr/bin/env bash
# Paste a message file into a worker's Codex pane and submit it.
# Usage: send.sh PANE_ID MESSAGE_FILE
set -euo pipefail
pane=$1
file=$2
buffer="supervisor-$$"
tmux load-buffer -b "$buffer" "$file"
tmux paste-buffer -d -p -b "$buffer" -t "$pane"
sleep 0.5
tmux send-keys -t "$pane" Enter
