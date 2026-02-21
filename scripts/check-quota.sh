#!/usr/bin/env bash
# check-quota.sh — check Claude Max quota usage via undocumented OAuth API

set -euo pipefail

CREDENTIALS="$HOME/.claude/.credentials.json"
USAGE_API="https://api.anthropic.com/api/oauth/usage"

token=$(jq -r '.claudeAiOauth.accessToken' "$CREDENTIALS")

curl -sS "$USAGE_API" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code/2.1.49" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" | jq .
