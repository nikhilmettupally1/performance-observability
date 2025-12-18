#!/bin/bash
set -euo pipefail

LOCKFILE="/home/nutanix/data/locks/otel-collector"
OUTCSV="otelcol_10m_usage_suppress_false.csv"
SUMMARY="otelcol_10m_usage_summary_suppress_false.txt"

INTERVAL=5
DURATION_SEC=$((10*60))
END_TS=$(( $(date +%s) + DURATION_SEC ))

# CSV header
echo "timestamp,pid,cpu_pct,mem_pct,rss_kb" > "$OUTCSV"

# Stats
count=0
sum_cpu=0
sum_mem=0
sum_rss=0
max_cpu=0
max_mem=0
max_rss=0
max_cpu_ts=""
max_mem_ts=""
max_rss_ts=""

while [ "$(date +%s)" -lt "$END_TS" ]; do
  ts="$(date '+%F %T')"
  # Find OTEL PID from genesis lockfile holders.
  # Genesis often starts services via a /bin/bash -lc wrapper; that wrapper can
  # match otelcol in argv. To sample the *real* otelcol process, match the
  # executable name via /proc/<pid>/exe.
  PID=$(
    lsof -t "$LOCKFILE" 2>/dev/null | while read -r p; do
      exe=$(readlink -f "/proc/$p/exe" 2>/dev/null || true)
      [ "$(basename "$exe")" = "otelcol" ] && echo "$p" && break
    done
  ) || PID=""

  if [ -z "${PID:-}" ]; then
    echo "$ts,,NA,NA,NA" >> "$OUTCSV"
    sleep "$INTERVAL"
    continue
  fi

  line="$(ps -p "$PID" -o %cpu,%mem,rss --no-headers 2>/dev/null || true)"
  if [ -z "$line" ]; then
    echo "$ts,$PID,NA,NA,NA" >> "$OUTCSV"
    sleep "$INTERVAL"
    continue
  fi

  cpu="$(awk '{print $1}' <<<"$line")"
  mem="$(awk '{print $2}' <<<"$line")"
  rss="$(awk '{print $3}' <<<"$line")"

  echo "$ts,$PID,$cpu,$mem,$rss" >> "$OUTCSV"

  count=$((count + 1))
  sum_cpu="$(awk -v s="$sum_cpu" -v x="$cpu" 'BEGIN{printf "%.6f", s+x}')"
  sum_mem="$(awk -v s="$sum_mem" -v x="$mem" 'BEGIN{printf "%.6f", s+x}')"
  sum_rss=$((sum_rss + rss))

  awk -v x="$cpu" -v m="$max_cpu" 'BEGIN{exit !(x>m)}' && { max_cpu="$cpu"; max_cpu_ts="$ts"; }
  awk -v x="$mem" -v m="$max_mem" 'BEGIN{exit !(x>m)}' && { max_mem="$mem"; max_mem_ts="$ts"; }
  [ "$rss" -gt "$max_rss" ] && { max_rss="$rss"; max_rss_ts="$ts"; }

  sleep "$INTERVAL"
done

if [ "$count" -gt 0 ]; then
  avg_cpu="$(awk -v s="$sum_cpu" -v c="$count" 'BEGIN{printf "%.3f", s/c}')"
  avg_mem="$(awk -v s="$sum_mem" -v c="$count" 'BEGIN{printf "%.3f", s/c}')"
  avg_rss=$((sum_rss / count))
else
  avg_cpu="NA"; avg_mem="NA"; avg_rss="NA"
fi

{
  echo "Period: 10m"
  echo "Interval: ${INTERVAL}s"
  echo "Valid samples: $count"
  echo
  echo "AVG  CPU(%): $avg_cpu"
  echo "MAX  CPU(%): $max_cpu  @ $max_cpu_ts"
  echo
  echo "AVG  MEM(%): $avg_mem"
  echo "MAX  MEM(%): $max_mem  @ $max_mem_ts"
  echo
  echo "AVG  RSS(KB): $avg_rss"
  echo "MAX  RSS(KB): $max_rss  @ $max_rss_ts"
  echo
  echo "CSV: $OUTCSV"
} | tee "$SUMMARY"
