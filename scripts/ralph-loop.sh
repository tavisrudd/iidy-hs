#!/usr/bin/env bash
# ralph-loop.sh — autonomous Claude Code work loop for iidy-hs
# Runs claude in headless mode, restarts on context exhaustion,
# sleeps until quota reset on rate limit, exits on unknown errors.

set -euo pipefail

WORKDIR="$HOME/src/iidy-hs"
LOGDIR="/tmp/claude-ralph-loop"

mkdir -p "$LOGDIR"

prompt='Read @WORKPLAN.md and your memory files in .claude/projects/-home-tavis-src-iidy-hs/memory/. Continue from where you left off. Work autonomously through the workplan phases. Before context gets low (~15% remaining), update your memory file and WORKPLAN.md session tracking, then exit cleanly.'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGDIR/loop.log"; }

parse_reset_time_from_stderr() {
    # Extract reset time from "Your limit will reset at 2pm (America/New_York)"
    local stderr_file="$1"
    local reset_line
    reset_line=$(grep -i "will reset at" "$stderr_file" 2>/dev/null | tail -1) || return 1

    # Extract time and timezone: "reset at 2pm (America/New_York)"
    local time_part tz_part
    time_part=$(echo "$reset_line" | sed -n 's/.*reset at \([^ ]*\).*/\1/p')
    tz_part=$(echo "$reset_line" | sed -n 's/.*(\([^)]*\)).*/\1/p')

    if [[ -n "$time_part" && -n "$tz_part" ]]; then
        # Convert to epoch using date command
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
    local stderr_file="$1"
    local reset_epoch

    # Try parsing from stderr message first
    if reset_epoch=$(parse_reset_time_from_stderr "$stderr_file"); then
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

session_num=0

while true; do
    session_num=$(( session_num + 1 ))
    local_log="$LOGDIR/session-${session_num}"
    mkdir -p "$local_log"

    log "=== Starting session $session_num ==="

    set +e
    claude -p "$prompt" \
        --allowedTools 'Bash,Read,Write,Edit,Glob,Grep,Task,WebSearch,WebFetch,LSP,NotebookEdit' \
        --dangerously-skip-permissions \
        2>"$local_log/stderr.log" \
        >"$local_log/stdout.log"
    rc=$?
    set -e

    log "Session $session_num exited with code $rc"

    # Check for quota exhaustion
    if grep -qi "usage limit reached\|rate limit" "$local_log/stderr.log" 2>/dev/null; then
        log "Detected quota exhaustion"
        sleep_until_reset "$local_log/stderr.log"
        continue
    fi

    # Check for auth errors
    if grep -qi "unauthorized\|authentication\|401" "$local_log/stderr.log" 2>/dev/null; then
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
    log "Unknown error (rc=$rc). Stderr tail:"
    tail -5 "$local_log/stderr.log" 2>/dev/null | tee -a "$LOGDIR/loop.log"
    log "Retrying in 60 seconds."
    sleep 60
done
