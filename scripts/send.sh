#!/usr/bin/env bash
# Usage: ./scripts/send.sh [file] [tenant]
# Sends a bulk body to Logstash exactly as a legacy client would: untouched NDJSON.
set -euo pipefail

FILE="${1:-sample/bulk-acme.ndjson}"
TENANT="${2:-acme}"
REQ_ID="$(uuidgen)"

curl -sS -X POST "http://localhost:${LOGSTASH_PORT:-8080}/" \
  -H "Content-Type: application/x-ndjson" \
  -H "X-Request-Id: ${REQ_ID}" \
  -H "X-Tenant-Id: ${TENANT}" \
  --data-binary "@${FILE}"
echo
echo "sent ${FILE} as tenant=${TENANT} request=${REQ_ID}"
