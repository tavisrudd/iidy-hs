#!/usr/bin/env bash
# PreToolUse hook: block Agent tool calls that use isolation: worktree.
# This parameter auto-cherry-picks commits to main and deletes the worktree,
# bypassing review and pre-commit hooks. See CLAUDE.md for safe alternatives.
set -euo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name')

if [ "$tool_name" != "Agent" ]; then
    exit 0
fi

isolation=$(echo "$input" | jq -r '.tool_input.isolation // empty')

if [ "$isolation" = "worktree" ]; then
    echo "BLOCKED: isolation: worktree auto-cherry-picks to main and bypasses hooks. Use regular parallel agents (Option A) or manual git worktree add (Option B). See CLAUDE.md." >&2
    exit 2
fi

exit 0
