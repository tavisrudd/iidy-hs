#!/usr/bin/env bash
# check-quota.sh — check Claude Max quota usage via undocumented OAuth API

set -euo pipefail

PRETTY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--pretty) PRETTY=true; shift ;;
        *) echo "Usage: check-quota.sh [-p|--pretty]" >&2; exit 1 ;;
    esac
done

CREDENTIALS="$HOME/.claude/.credentials.json"
USAGE_API="https://api.anthropic.com/api/oauth/usage"

token=$(jq -r '.claudeAiOauth.accessToken' "$CREDENTIALS")

json=$(curl -sS "$USAGE_API" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code/2.1.49" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20")

if [[ "$PRETTY" == false ]]; then
    echo "$json" | jq .
    exit 0
fi

local_time() {
    local iso="$1" fmt="${2:-%-I:%M%P}"
    if [[ "$iso" == "null" || -z "$iso" ]]; then
        echo "n/a"
    else
        date -d "$iso" "+$fmt"
    fi
}

h5_pct=$(echo "$json" | jq -r '.five_hour.utilization // 0')
h5_reset=$(echo "$json" | jq -r '.five_hour.resets_at // "null"')
wk_pct=$(echo "$json" | jq -r '.seven_day.utilization // 0')
wk_reset=$(echo "$json" | jq -r '.seven_day.resets_at // "null"')

printf '%g%% used / 5hr (%s), %g%% used / wk (%s)\n' \
    "$h5_pct" "$(local_time "$h5_reset")" \
    "$wk_pct" "$(local_time "$wk_reset" '%a %-I:%M%P')"
