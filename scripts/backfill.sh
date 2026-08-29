#!/usr/bin/env bash
# Drives the enrichment backfill by hammering /enrich/run until nothing remains.
# Usage: ENRICH_ADMIN_TOKEN=... ./scripts/backfill.sh [api-base]
# Batch of 3 = free-plan Workers subrequest budget (see server/src/routes/enrich.ts).
set -euo pipefail
BASE="${1:-https://mixtape-api.goalympics.workers.dev}"
: "${ENRICH_ADMIN_TOKEN:?set ENRICH_ADMIN_TOKEN}"

while :; do
  OUT=$(curl -sf -X POST "$BASE/enrich/run?limit=3" -H "X-Admin-Token: $ENRICH_ADMIN_TOKEN") || {
    echo "$(date +%H:%M:%S) batch failed; retrying in 10s" >&2
    sleep 10
    continue
  }
  echo "$(date +%H:%M:%S) $OUT"
  REMAINING=$(echo "$OUT" | sed -n 's/.*"remaining":\([0-9]*\).*/\1/p')
  [ "${REMAINING:-0}" -le 0 ] && break
  sleep 1
done
curl -sf "$BASE/enrich/status" -H "X-Admin-Token: $ENRICH_ADMIN_TOKEN"
echo
