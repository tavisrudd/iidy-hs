#!/usr/bin/env bash
# PreToolUse hook: block Edit/Write operations that target files outside
# the worktree when running in a worktree sub-agent.
#
# Only enforced when cwd contains .claude/worktrees/ (i.e., we're a
# worktree sub-agent). Main agent is never blocked.
set -euo pipefail

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')
tool_name=$(echo "$input" | jq -r '.tool_name')

# Only enforce in worktree contexts
if [[ "$cwd" != */.claude/worktrees/* && "$cwd" != */.worktrees/* ]]; then
    exit 0
fi

# Only check file-writing tools
if [[ "$tool_name" != "Edit" && "$tool_name" != "Write" && "$tool_name" != "NotebookEdit" ]]; then
    exit 0
fi

file_path=$(echo "$input" | jq -r '.tool_input.file_path')

# Resolve to absolute path if relative
if [[ "$file_path" != /* ]]; then
    file_path="$cwd/$file_path"
fi

# Normalize (resolve .., symlinks) — use realpath on existing parent dir
# For new files, check the parent directory
if [ -e "$file_path" ]; then
    resolved=$(realpath "$file_path")
else
    parent=$(dirname "$file_path")
    if [ -d "$parent" ]; then
        resolved=$(realpath "$parent")/$(basename "$file_path")
    else
        resolved="$file_path"
    fi
fi

resolved_cwd=$(realpath "$cwd")

# Check if the resolved path is under the worktree
if [[ "$resolved" != "$resolved_cwd"/* ]]; then
    echo "BLOCKED: $tool_name target '$file_path' is outside worktree '$cwd'. Worktree sub-agents must only write within their worktree." >&2
    exit 2
fi

exit 0
