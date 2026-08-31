#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEV_VARS_FILE=${DEV_VARS_FILE:-"$SCRIPT_DIR/../.dev.vars"}
APPLY=false
LIMIT=300
MAX_BATCHES=${MAX_BATCHES:-10000}
BACKOFF_SLEEP_SECONDS=${BACKOFF_SLEEP_SECONDS:-5}

usage() {
  printf '%s\n' 'Usage: scripts/backfill-artwork.sh [--apply] [--limit 1..300] [--base URL]'
  printf '%s\n' 'Default mode reads and prints artwork status only. --apply runs bounded batches.'
}

read_dev_var() {
  key=$1
  [ -f "$DEV_VARS_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        value=${line#*=}
        value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$value" in
          \"*\") value=${value#\"}; value=${value%\"} ;;
          \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        printf '%s' "$value"
        return 0
        ;;
    esac
  done < "$DEV_VARS_FILE"
  return 1
}

BASE_OVERRIDE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    --limit)
      [ "$#" -ge 2 ] || { printf '%s\n' 'error: --limit requires a value' >&2; exit 2; }
      LIMIT=$2
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || { printf '%s\n' 'error: --base requires a value' >&2; exit 2; }
      BASE_OVERRIDE=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf '%s\n' 'error: unknown argument' >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 300 ]; then
  printf '%s\n' 'error: limit must be an integer from 1 to 300' >&2
  exit 2
fi

TOKEN=${ENRICH_ADMIN_TOKEN:-}
if [ -z "$TOKEN" ]; then TOKEN=$(read_dev_var ENRICH_ADMIN_TOKEN || true); fi
if [ -z "$TOKEN" ]; then
  printf '%s\n' 'error: ENRICH_ADMIN_TOKEN is required' >&2
  exit 2
fi

BASE=$BASE_OVERRIDE
if [ -z "$BASE" ]; then BASE=${ARTWORK_API_BASE:-}; fi
if [ -z "$BASE" ]; then BASE=$(read_dev_var BETTER_AUTH_URL || true); fi
if [ -z "$BASE" ]; then
  printf '%s\n' 'error: API base is required via --base, ARTWORK_API_BASE, or BETTER_AUTH_URL' >&2
  exit 2
fi
case "$BASE" in
  http://*|https://*) ;;
  *) printf '%s\n' 'error: API base must be an HTTP(S) URL' >&2; exit 2 ;;
esac
BASE=${BASE%/}

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/mixtape-artwork.XXXXXX")
trap 'rm -f "$BODY_FILE"' EXIT HUP INT TERM

request() {
  method=$1
  path=$2
  attempt=0
  while :; do
    : > "$BODY_FILE"
    set +e
    status=$(curl \
      --silent \
      --output "$BODY_FILE" \
      --write-out '%{http_code}' \
      --connect-timeout 10 \
      --max-time 120 \
      --request "$method" \
      --header "X-Admin-Token: $TOKEN" \
      "$BASE$path" 2>/dev/null)
    curl_status=$?
    set -e

    if [ "$curl_status" -ne 0 ]; then
      printf '%s\n' 'error: request transport failed' >&2
      exit 1
    fi
    case "$status" in
      2??) return 0 ;;
      429|5??)
        attempt=$((attempt + 1))
        if [ "$attempt" -lt 4 ]; then
          sleep "$BACKOFF_SLEEP_SECONDS"
          continue
        fi
        ;;
    esac
    printf 'error: request failed (HTTP %s)\n' "$status" >&2
    exit 1
  done
}

parse_counts() {
  fields=$1
  node -e '
    const fs = require("node:fs");
    try {
      const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const fields = process.argv[2].split(",");
      const values = fields.map((field) => payload[field]);
      if (!values.every((value) => Number.isInteger(value) && value >= 0)) process.exit(1);
      process.stdout.write(values.join(" "));
    } catch { process.exit(1); }
  ' "$BODY_FILE" "$fields" 2>/dev/null
}

print_status() {
  request GET '/enrich/artwork/status'
  counts=$(parse_counts 'tracks,withArtwork,missingArtwork,retryable') || {
    printf '%s\n' 'error: malformed status response' >&2
    exit 1
  }
  set -- $counts
  printf 'status tracks=%s with_artwork=%s missing_artwork=%s retryable=%s\n' "$1" "$2" "$3" "$4"
  RETRYABLE=$4
}

print_status
if [ "$APPLY" != true ]; then
  printf '%s\n' 'dry-run: no artwork writes requested'
  exit 0
fi

batch=0
while [ "$RETRYABLE" -gt 0 ]; do
  batch=$((batch + 1))
  if [ "$batch" -gt "$MAX_BATCHES" ]; then
    printf '%s\n' 'error: maximum batch count reached' >&2
    exit 1
  fi
  request POST "/enrich/artwork/run?limit=$LIMIT"
  counts=$(parse_counts 'processed,matched,missing,failed,remaining') || {
    printf '%s\n' 'error: malformed batch response' >&2
    exit 1
  }
  set -- $counts
  printf 'batch=%s processed=%s matched=%s missing=%s failed=%s remaining=%s\n' \
    "$batch" "$1" "$2" "$3" "$4" "$5"
  if [ "$1" -eq 0 ] && [ "$5" -gt 0 ]; then
    printf '%s\n' 'error: artwork backfill made no progress' >&2
    exit 1
  fi
  RETRYABLE=$5
done

print_status
