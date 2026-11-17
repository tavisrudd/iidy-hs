#!/usr/bin/env bash
# Worker status, terse by default: one line per worker plus one summary line.
# Usage: status.sh [-v]   (-v adds the last action and recent activity)
#
# Codex workers are listed in panes.txt; Claude sub-agent worktrees
# (worktrees/claude-C<ID>) are listed from the worktree directory.
set -uo pipefail
cache=$HOME/src/iidy-hs/.supervisor
run=$cache
repo=$HOME/src/iidy-hs
worktrees=$HOME/.cache/iidy-hs/worktrees
verbose=${1:-}
mailbox=$run/mailbox.log
panes=${IIDY_SUPERVISOR_PANES:-$run/panes.txt}

branch_info() {
  local wt=$1
  [[ -d $wt ]] || return 0
  local ahead behind dirty
  ahead=$(git -C "$wt" rev-list --count main..HEAD 2>/dev/null)
  behind=$(git -C "$wt" rev-list --count HEAD..main 2>/dev/null)
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l)
  echo " $(git -C "$wt" branch --show-current 2>/dev/null) +$ahead/-$behind dirty:$dirty"
}

if [[ -r $panes ]]; then
  for entry in $(tr ' ' '\n' < "$panes"); do
    worker=${entry%%=*}
    pane=${entry#*=}
    if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$pane"; then
      echo "$worker MISSING-PANE"
      continue
    fi
    pane_pid=$(tmux display -p -t "$pane" '#{pane_pid}')
    screen=$(tmux capture-pane -p -t "$pane" -S -60)
    # Codex shows "Working (" or a background-terminal wait while busy; its
    # input prompt is always visible, so the prompt alone means nothing.
    if grep -qE 'Working \(|Waiting for background terminal|esc to interrupt' <<<"$(tail -8 <<<"$screen")"; then
      state=BUSY
    elif ! pstree -p "$pane_pid" | grep -q 'codex('; then
      state=NO-CODEX
    else
      state=IDLE
    fi
    line=$(grep "worker=$worker " "$mailbox" 2>/dev/null | tail -1)
    mail=""
    if [[ -n $line ]]; then
      mail=" last=$(grep -oE 'card=C[0-9]+' <<<"$line")/$(grep -oE 'state=[a-z-]+' <<<"$line" | cut -d= -f2)@$(cut -c12-16 <<<"$line")"
    fi
    echo "$worker $state$(branch_info "$worktrees/$worker")$mail"
    if [[ $verbose == -v ]]; then
      grep -E '^• ' <<<"$screen" | grep -vE 'Working|Waiting' | tail -1 | cut -c1-110 | sed 's/^/  /'
      grep -E '^(• |  └ )' <<<"$screen" | tail -4 | cut -c1-110 | sed 's/^/    /'
    fi
  done
fi

for wt in "$worktrees"/claude-C*; do
  [[ -d $wt ]] || continue
  echo "$(basename "$wt") SUB$(branch_info "$wt")"
done

notes=$(git -C "$repo" status --porcelain -- notes | awk '{print $2}' | cut -d/ -f2 | sort -u | tr '\n' ' ')
# Nix GHC binaries are named ghc-<version>; pgrep matches comm by regex.
builds=$(pgrep -c '^ghc' 2>/dev/null || true)
locked=no
if [[ -e $cache/build.lock ]] && ! flock -n "$cache/build.lock" true 2>/dev/null; then
  locked=yes
fi
avail=$(( $("$repo/scripts/avail-mem-kb") / 1024 / 1024 ))
echo "notes-dirty: ${notes:-none} · build-lock: $locked · ghc: ${builds:-0} · mem-avail: ${avail}G · load $(cut -d' ' -f1 /proc/loadavg)"
