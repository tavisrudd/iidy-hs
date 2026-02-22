#!/usr/bin/env bash
# ralph-loop-live.sh — autonomous Claude Code work loop with live output
# Uses `script -f` to give claude a PTY so output streams to the tmux
# pane in real-time instead of buffering until exit.
# Restarts on context exhaustion, sleeps until quota reset on rate limit.

set -euo pipefail

WORKDIR="$HOME/src/iidy-hs"
LOGDIR="/tmp/claude-ralph-loop"

mkdir -p "$LOGDIR"

prompt='Read @WORKPLAN.md and your memory files in .claude/projects/-home-tavis-src-iidy-hs/memory/. Continue from where you left off. Work autonomously through the workplan phases. Before context gets low (~15% remaining), update your memory file and WORKPLAN.md session tracking, then exit cleanly.'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGDIR/loop.log"; }

# Strip ANSI escape sequences for reliable grep matching on script output
strip_ansi() { sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\([0-9;]*[a-zA-Z]//g; s/\r//g' "$1"; }

parse_reset_time_from_output() {
    # Extract reset time from "Your limit will reset at 2pm (America/New_York)"
    local output_file="$1"
    local reset_line
    reset_line=$(strip_ansi "$output_file" | grep -i "will reset at" | tail -1) || return 1

    # Extract time and timezone: "reset at 2pm (America/New_York)"
    local time_part tz_part
    time_part=$(echo "$reset_line" | sed -n 's/.*reset at \([^ ]*\).*/\1/p')
    tz_part=$(echo "$reset_line" | sed -n 's/.*(\\([^)]*\\)).*/\1/p')

    if [[ -n "$time_part" && -n "$tz_part" ]]; then
        local today
        today=$(TZ="$tz_part" date '+%Y-%m-%d')
        local reset_epoch
        reset_epoch=$(TZ="$tz_part" date -d "$today $time_part" '+%s' 2>/dev/null) || return 1
        local now_epoch
        now_epoch=$(date '+%s')

        # If reset time is in the past, it's tomorrow
        if (( reset_epoch <= now_epoch )); then
            reset_epoch=$(( reset_epoch + 86400 ))
        fi

        echo "$reset_epoch"
        return 0
    fi
    return 1
}

sleep_until_reset() {
    local output_file="$1"
    local reset_epoch

    # Try parsing from output
    if reset_epoch=$(parse_reset_time_from_output "$output_file"); then
        local now_epoch
        now_epoch=$(date '+%s')
        local wait_secs=$(( reset_epoch - now_epoch + 60 ))  # +60s buffer
        if (( wait_secs > 0 && wait_secs < 43200 )); then  # sanity: max 12hr
            local reset_human
            reset_human=$(date -d "@$reset_epoch" '+%H:%M %Z')
            log "Quota exhausted. Sleeping until $reset_human ($wait_secs seconds)"
            sleep "$wait_secs"
            return 0
        fi
    fi

    # Last resort: sleep 5 hours
    log "Could not determine reset time. Sleeping 5 hours."
    sleep 18000
}

# Continue session numbering from any existing sessions
session_num=0
if existing=$(ls -d "$LOGDIR"/session-* 2>/dev/null | tail -1); then
    session_num=$(basename "$existing" | sed 's/session-//')
fi

cd "$WORKDIR"

while true; do
    session_num=$(( session_num + 1 ))
    local_log="$LOGDIR/session-${session_num}"
    mkdir -p "$local_log"

    log "=== Starting session $session_num ==="

    # script -e: propagate child exit code
    # script -q: suppress "Script started/done" banners
    # script -f: flush after each write (real-time output)
    # script -c: run command instead of interactive shell
    set +e
    script -eqf -c "claude -p '$prompt' \
        --allowedTools 'Bash,Read,Write,Edit,Glob,Grep,Task,WebSearch,WebFetch,LSP,NotebookEdit' \
        --dangerously-skip-permissions" \
        "$local_log/output.log"
    rc=$?
    set -e

    log "Session $session_num exited with code $rc"

    # Check for quota exhaustion (strip ANSI codes from script output)
    if strip_ansi "$local_log/output.log" | grep -qi "usage limit reached\|rate limit" 2>/dev/null; then
        log "Detected quota exhaustion"
        sleep_until_reset "$local_log/output.log"
        continue
    fi

    # Check for auth errors
    if strip_ansi "$local_log/output.log" | grep -qi "unauthorized\|authentication\|401" 2>/dev/null; then
        log "ERROR: Auth failure. Stopping loop."
        exit 1
    fi

    # Normal exit (context exhaustion or clean exit) — brief pause and restart
    if [[ $rc -eq 0 ]]; then
        log "Clean exit. Restarting in 10 seconds."
        sleep 10
        continue
    fi

    # Unknown error — pause longer, retry
    log "Unknown error (rc=$rc). Output tail:"
    tail -5 "$local_log/output.log" 2>/dev/null | tee -a "$LOGDIR/loop.log"
    log "Retrying in 60 seconds."
    sleep 60
done
