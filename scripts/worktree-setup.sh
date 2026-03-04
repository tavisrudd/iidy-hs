#!/usr/bin/env bash
# WorktreeCreate hook: ensure new worktrees have correct git config.
# Receives JSON on stdin with session info including cwd (worktree path).
set -euo pipefail

input=$(cat)
worktree_path=$(echo "$input" | jq -r '.cwd')

if [ -z "$worktree_path" ] || [ "$worktree_path" = "null" ]; then
    echo "worktree-setup: ok (no cwd)"
    exit 0  # can't determine path, don't block
fi

# Wait briefly for worktree to be ready (hook may fire before git finishes)
if [ ! -d "$worktree_path" ]; then
    echo "worktree-setup: ok (path not yet created, will be configured by git)"
    exit 0
fi

# Verify core.hooksPath points to .githooks (relative, works in worktrees)
current_hooks=$(git -C "$worktree_path" config core.hooksPath 2>/dev/null || true)
if [ "$current_hooks" != ".githooks" ]; then
    git -C "$worktree_path" config --local core.hooksPath .githooks
fi

# Ensure GPG signing is disabled (YubiKey hangs in non-interactive agents)
current_gpg=$(git -C "$worktree_path" config commit.gpgsign 2>/dev/null || true)
if [ "$current_gpg" != "false" ]; then
    git -C "$worktree_path" config --local commit.gpgsign false
fi

echo "worktree-setup: ok"
