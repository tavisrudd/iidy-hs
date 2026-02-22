#!/usr/bin/env bash
# ralph-loop-progress.sh — autonomous Claude Code work loop with progress log
# Claude writes structured progress updates to a log file that can be
# monitored with `tail -f /tmp/claude-ralph-loop/progress.log`.
# Stdout/stderr are still captured to per-session files for error detection.

set -euo pipefail

WORKDIR="$HOME/src/iidy-hs"
LOGDIR="/tmp/claude-ralph-loop"
PROGRESS_LOG="$LOGDIR/progress.log"

mkdir -p "$LOGDIR"

prompt='Read @WORKPLAN.md and your memory files in .claude/projects/-home-tavis-src-iidy-hs/memory/. Continue from where you left off. Work autonomously through the workplan phases. Before context gets low (~15% remaining), update your memory file and WORKPLAN.md session tracking, then exit cleanly.

PROGRESS LOGGING: Throughout your work, periodically append short status lines to /tmp/claude-ralph-loop/progress.log using the Bash tool. Do this:
- At session start (what you plan to work on)
- After each meaningful milestone (file created, module compiles, tests pass, commit made)
- On errors or blockers
- Before exiting (summary of what was accomplished)
Format each line as: echo "[$(date +%H:%M:%S)] <message>" >> /tmp/claude-ralph-loop/progress.log
Keep messages to one line, ~80 chars. Example: [14:32:07] Phase 1: cabal build succeeds, 0 warnings'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGDIR/loop.log"; }

parse_reset_time_from_stderr() {
    local stderr_file="$1"
    local reset_line
    reset_line=$(grep -i "will reset at" "$stderr_file" 2>/dev/null | tail -1) || return 1

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

    if reset_epoch=$(parse_reset_time_from_stderr "$stderr_file"); then
        local now_epoch
        now_epoch=$(date '+%s')
        local wait_secs=$(( reset_epoch - now_epoch + 60 ))
        if (( wait_secs > 0 && wait_secs < 43200 )); then
            local reset_human
            reset_human=$(date -d "@$reset_epoch" '+%H:%M %Z')
            log "Quota exhausted. Sleeping until $reset_human ($wait_secs seconds)"
            echo "[$(date '+%H:%M:%S')] LOOP: Quota exhausted. Sleeping until $reset_human" >> "$PROGRESS_LOG"
            sleep "$wait_secs"
            return 0
        fi
    fi

    log "Could not determine reset time. Sleeping 5 hours."
    echo "[$(date '+%H:%M:%S')] LOOP: Could not determine reset time. Sleeping 5 hours." >> "$PROGRESS_LOG"
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
    echo "[$(date '+%H:%M:%S')] LOOP: Starting session $session_num" >> "$PROGRESS_LOG"

    set +e
    claude -p "$prompt" \
        --allowedTools 'Bash,Read,Write,Edit,Glob,Grep,Task,WebSearch,WebFetch,LSP,NotebookEdit' \
        --dangerously-skip-permissions \
        2>"$local_log/stderr.log" \
        >"$local_log/stdout.log"
    rc=$?
    set -e

    log "Session $session_num exited with code $rc"
    echo "[$(date '+%H:%M:%S')] LOOP: Session $session_num exited (rc=$rc)" >> "$PROGRESS_LOG"

    # Check for quota exhaustion
    if grep -qi "usage limit reached\|rate limit" "$local_log/stderr.log" 2>/dev/null; then
        log "Detected quota exhaustion"
        sleep_until_reset "$local_log/stderr.log"
        continue
    fi

    # Check for auth errors
    if grep -qi "unauthorized\|authentication\|401" "$local_log/stderr.log" 2>/dev/null; then
        log "ERROR: Auth failure. Stopping loop."
        echo "[$(date '+%H:%M:%S')] LOOP: ERROR — Auth failure. Stopping." >> "$PROGRESS_LOG"
        exit 1
    fi

    # Normal exit — brief pause and restart
    if [[ $rc -eq 0 ]]; then
        log "Clean exit. Restarting in 10 seconds."
        sleep 10
        continue
    fi

    # Unknown error — pause longer, retry
    log "Unknown error (rc=$rc). Stderr tail:"
    tail -5 "$local_log/stderr.log" 2>/dev/null | tee -a "$LOGDIR/loop.log"
    log "Retrying in 60 seconds."
    echo "[$(date '+%H:%M:%S')] LOOP: Unknown error (rc=$rc). Retrying in 60s." >> "$PROGRESS_LOG"
    sleep 60
done
