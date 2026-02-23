#!/usr/bin/env bash
# ralph-loop.sh — autonomous Claude Code work loop for iidy-hs
# Runs claude in headless mode, restarts on context exhaustion,
# sleeps until quota reset on rate limit, exits on unknown errors.

set -euo pipefail

WORKDIR="$HOME/src/iidy-hs"
LOGDIR="/tmp/claude-ralph-loop"
STOPFILE="$WORKDIR/.ralph-stop"
NTFY_TOPIC="tavis-iidy-port-2026"
QUOTA_SCRIPT="$WORKDIR/scripts/check-quota.sh"
FIVE_HR_MAX_UTIL=93   # leave headroom
WEEKLY_MAX_UTIL=99    # leave headroom

mkdir -p "$LOGDIR"
mkdir -p "$WORKDIR/.msgs"

prompt='Read @WORKPLAN.md and your memory files in .claude/projects/-home-tavis-src-iidy-hs/memory/. Continue from where you left off. Work autonomously through the workplan phases but update your status there as you go. Before context gets low (~15% remaining), update your memory file and WORKPLAN.md session tracking, then exit cleanly.

Pay attention to the claude.md note about reading and replying to the .msgs folder. Do that NOW.
'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGDIR/loop.log"; }
ntfy() { curl -s -H "Priority: ${2:-default}" -H "Tags: wrench" -d "$1" "ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true; }

check_stop_file() {
    if [[ -f "$STOPFILE" ]]; then
        log "Stop file exists ($STOPFILE). Exiting."
        ntfy "Ralph loop stopped (.ralph-stop exists)" low
        exit 0
    fi
}

# Check quota, return 0 if OK, 1 if insufficient.
# On API failure, log warning and return 0 (optimistic).
check_quota() {
    local quota_json
    quota_json=$(bash "$QUOTA_SCRIPT" 2>/dev/null) || {
        log "WARNING: Quota check failed (API error). Proceeding optimistically."
        return 0
    }

    local five_hr_util weekly_util
    five_hr_util=$(echo "$quota_json" | jq -r '.five_hour.utilization // 0')
    weekly_util=$(echo "$quota_json" | jq -r '.seven_day.utilization // 0')

    log "Quota: 5hr=${five_hr_util}% (max ${FIVE_HR_MAX_UTIL}%), weekly=${weekly_util}% (max ${WEEKLY_MAX_UTIL}%)"

    # Compare as integers (jq outputs floats, truncate with printf)
    local five_int weekly_int
    five_int=$(printf '%.0f' "$five_hr_util")
    weekly_int=$(printf '%.0f' "$weekly_util")

    if (( five_int > FIVE_HR_MAX_UTIL )); then
        local resets_at
        resets_at=$(echo "$quota_json" | jq -r '.five_hour.resets_at // "unknown"')
        log "5hr quota too high (${five_hr_util}% > ${FIVE_HR_MAX_UTIL}%). Resets at: $resets_at"
        return 1
    fi

    if (( weekly_int > WEEKLY_MAX_UTIL )); then
        local resets_at
        resets_at=$(echo "$quota_json" | jq -r '.seven_day.resets_at // "unknown"')
        log "Weekly quota too high (${weekly_util}% > ${WEEKLY_MAX_UTIL}%). Resets at: $resets_at"
        return 1
    fi

    return 0
}

wait_for_quota() {
    local wait_secs=300  # check every 5 minutes
    ntfy "Ralph loop waiting for quota (5hr>${FIVE_HR_MAX_UTIL}% or weekly>${WEEKLY_MAX_UTIL}%)" low
    while ! check_quota; do
        check_stop_file
        log "Waiting ${wait_secs}s for quota to recover..."
        sleep "$wait_secs"
    done
}

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

    # Pre-flight checks
    check_stop_file

    if ! check_quota; then
        wait_for_quota
    fi

    check_stop_file  # re-check after potential wait

    # Check if quota is low enough to warn Claude
    session_prompt="$prompt"
    quota_json=$(bash "$QUOTA_SCRIPT" 2>/dev/null) || true
    if [[ -n "$quota_json" ]]; then
        five_hr_util=$(echo "$quota_json" | jq -r '.five_hour.utilization // 0')
        five_int=$(printf '%.0f' "$five_hr_util")
        if (( five_int >= 80 )); then
            session_prompt="$prompt

LOW QUOTA WARNING: 5-hour quota is at ${five_hr_util}% utilization (~$(( 100 - five_int ))% remaining). Estimate what you can realistically accomplish in this budget and focus on that. Save state frequently (memory files, WORKPLAN.md session tracking, progress.log) — after every chunk or significant milestone, not just at the end. Do not exit early — use the remaining budget productively, just be disciplined about incremental saves."
        fi
    fi

    log "=== Starting session $session_num ==="
    ntfy "Ralph session $session_num starting"

    set +e
    claude -p "$session_prompt" \
        --allowedTools 'Bash,Read,Write,Edit,Glob,Grep,Task,WebSearch,WebFetch,LSP,NotebookEdit' \
        --dangerously-skip-permissions \
        2>"$local_log/stderr.log" \
        >"$local_log/stdout.log"
    rc=$?
    set -e

    log "Session $session_num exited with code $rc"
    ntfy "Ralph session $session_num exited (rc=$rc)"

    # Check for quota exhaustion
    if grep -qi "usage limit reached\|rate limit" "$local_log/stderr.log" 2>/dev/null; then
        log "Detected quota exhaustion"
        sleep_until_reset "$local_log/stderr.log"
        continue
    fi

    # Check for auth errors
    if grep -qi "unauthorized\|authentication\|401" "$local_log/stderr.log" 2>/dev/null; then
        log "ERROR: Auth failure. Stopping loop."
        ntfy "Ralph loop STOPPED: auth failure" high
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
    ntfy "Ralph session $session_num unknown error (rc=$rc)" high
    log "Retrying in 60 seconds."
    sleep 60
done
