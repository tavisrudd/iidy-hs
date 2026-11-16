#!/usr/bin/env bash
# usage: loop.sh BIN OUTDIR N RTSARGS...
BIN=$1; OUT=$2; N=$3; shift 3
for i in $(seq 1 "$N"); do
  avail=$(free -g | awk '/Mem:/{print $7}')
  if [ "$avail" -lt 6 ]; then echo "low mem $avail, waiting"; while [ "$(free -g | awk '/Mem:/{print $7}')" -lt 6 ]; do sleep 10; done; fi
  tag="run-$(date +%s)-$i"
  log="$OUT/$tag.log"
  start=$(date +%s.%N)
  EL=(); [ -n "$EVENTLOG" ] && EL=(+RTS -l "-ol$OUT/$tag.eventlog" -RTS)
  "$BIN" --timeout=20s "$@" "${EL[@]}" > "$log" 2>&1 < /dev/null &
  pid=$!
  # watchdog: 120s wall
  for t in $(seq 1 240); do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
  if kill -0 $pid 2>/dev/null; then
    ev="$OUT/$tag.hang"
    { echo "HANG pid=$pid"; for task in /proc/$pid/task/*; do echo "== $task $(cat $task/comm) wchan=$(cat $task/wchan) $(grep State $task/status)"; cat $task/stack 2>&1; done; echo "== last lines"; tail -20 "$log"; } > "$ev" 2>&1
    kill -9 $pid
    echo "$i HANG $log"
  fi
  wait $pid; rc=$?
  [ $rc -eq 0 ] && [ -n "$EVENTLOG" ] && rm -f "$OUT/$tag.eventlog"
  end=$(date +%s.%N)
  echo "$i rc=$rc time=$(echo "$end - $start" | bc) $(grep -E 'tests passed|out of' "$log" | tail -1) $*"
done
