#!/usr/bin/env bash
# usage: loop.sh OUTDIR LABEL N PATTERN [RTS args...]
# Runs the built test binary N times from the worktree root, one at a time.
# Event log goes to a single reused file (overwritten each run) and is copied
# aside only on a hang/failure. Watchdog at 60 s captures /proc state before
# any signal.
WT=/cache/tavis/iidy-hs/worktrees/claude-C6
BIN=$WT/dist-newstyle/build/x86_64-linux/ghc-9.12.3/iidy-hs-0.1.0.0/t/iidy-hs-test/build/iidy-hs-test/iidy-hs-test
OUT=$1; LABEL=$2; N=$3; PAT=$4; shift 4
cd "$WT" || exit 1
EL="$OUT/$LABEL.cur.eventlog"
for i in $(seq 1 "$N"); do
  while [ "$(free -g | awk '/Mem:/{print $7}')" -lt 6 ]; do echo "low mem, waiting"; sleep 10; done
  log="$OUT/$LABEL.cur.log"
  start=$(date +%s.%N)
  "$BIN" --timeout=20s -p "$PAT" +RTS "$@" -RTS > >(cat > "$log") 2>&1 < /dev/null &
  pid=$!
  for t in $(seq 1 600); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  hung=0
  if kill -0 $pid 2>/dev/null; then
    hung=1
    ev="$OUT/$LABEL-$i.hang"
    {
      echo "HANG pid=$pid label=$LABEL run=$i rts=$* date=$(date -Is)"
      cat /proc/loadavg
      for task in /proc/$pid/task/*; do
        echo "== $task $(cat $task/comm) wchan=$(cat $task/wchan) $(grep State $task/status)"
      done
      echo "== wchan counts"; for task in /proc/$pid/task/*; do cat $task/wchan; echo; done | sort | uniq -c
      echo "== fds"; ls -l /proc/$pid/fd
      echo "== cpu utime stime (now, +3s)"; awk '{print $14,$15}' /proc/$pid/stat; sleep 3; awk '{print $14,$15}' /proc/$pid/stat
      echo "== log"; cat "$log"
    } > "$ev" 2>&1
    cp "$EL" "$OUT/$LABEL-$i.eventlog"
    kill -INT $pid; sleep 5
    { echo "== after INT"; for task in /proc/$pid/task/*; do cat $task/wchan; echo; done | sort | uniq -c; awk '{print $14,$15}' /proc/$pid/stat; } >> "$ev" 2>&1
    kill -0 $pid 2>/dev/null && { echo "still alive after INT" >> "$ev"; kill -9 $pid; }
    echo "$i HANG $ev"
  fi
  wait $pid; rc=$?
  end=$(date +%s.%N)
  if [ $rc -ne 0 ] && [ $hung -eq 0 ]; then
    cp "$log" "$OUT/$LABEL-$i.fail.log"; cp "$EL" "$OUT/$LABEL-$i.fail.eventlog"
  fi
  echo "$i rc=$rc t=$(echo "$end - $start" | bc) $(grep -E 'tests passed|out of' "$log" | tail -1)"
done
