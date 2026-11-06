#!/usr/bin/env bash
# Sends the awkward requests a real bulk client can produce and checks what
# the gateway did with each one. Run it after the stack is up.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${LOGSTASH_PORT:-8080}"
ES="http://localhost:9200"
AUTH="elastic:${ELASTIC_PASSWORD:-changeme}"
IDX="orders-edge"
fail=0

check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi
}
send() { # content-type, tenant, request-id, body
  curl -sS -o /dev/null -X POST "http://localhost:${PORT}/" \
    -H "Content-Type: $1" -H "X-Tenant-Id: $2" -H "X-Request-Id: $3" --data-binary "$4"
}
count() { # json query body, index pattern
  curl -s -u "$AUTH" -H 'Content-Type: application/json' "$ES/$2/_count" -d "$1" | jq -r '.count // 0'
}

curl -s -u "$AUTH" -X DELETE "$ES/$IDX" >/dev/null   # start from a clean index

# 1. Some bulk clients send application/json, not application/x-ndjson
send "application/json" edge "edge-1-$(date +%s)" $'{ "index": { "_id": "ct1" } }\n{ "order_id": "CT-1", "total": 1.5, "level": "info" }\n'

# 2. index without an _id: Elasticsearch should generate one for each document
send "application/x-ndjson" edge "edge-2-$(date +%s)" $'{ "index": {} }\n{ "order_id": "NOID-1", "level": "info" }\n{ "index": {} }\n{ "order_id": "NOID-2", "level": "info" }\n'

# 3. a document whose own fields are named url, host and event
send "application/x-ndjson" edge "edge-3-$(date +%s)" $'{ "index": { "_id": "fields1" } }\n{ "order_id": "FIELDS-1", "url": "https://shop.example/cart", "host": "web-01", "event": "checkout", "level": "info" }\n'

# 4. a tenant name that would not be a valid index name
send "application/x-ndjson" "Bad/Tenant" "edge-4-$(date +%s)" $'{ "index": { "_id": "bad1" } }\n{ "order_id": "INVALID-TENANT", "level": "info" }\n'

# 5. a mapping error: total is a float in this index, here it is text
sleep 4
send "application/x-ndjson" edge "edge-5-$(date +%s)" $'{ "index": { "_id": "map1" } }\n{ "order_id": "BAD-MAPPING", "total": "not-a-number", "level": "info" }\n'

sleep 6
curl -s -u "$AUTH" -X POST "$ES/orders-*/_refresh" >/dev/null

check "application/json body is split into lines and indexed" "1" \
  "$(count '{"query":{"term":{"order_id.keyword":"CT-1"}}}' $IDX)"
check "two documents without _id both get stored"            "2" \
  "$(count '{"query":{"terms":{"order_id.keyword":["NOID-1","NOID-2"]}}}' $IDX)"
src=$(curl -s -u "$AUTH" "$ES/$IDX/_doc/fields1" | jq -r '._source | [.url, .host, .event] | join(",")')
check "client fields url, host and event are kept"           "https://shop.example/cart,web-01,checkout" "$src"
check "invalid tenant is rejected, not indexed"              "0" \
  "$(count '{"query":{"term":{"order_id.keyword":"INVALID-TENANT"}}}' 'orders-*')"
check "mapping error is not indexed"                         "0" \
  "$(count '{"query":{"term":{"order_id.keyword":"BAD-MAPPING"}}}' $IDX)"
dlq=$(docker compose exec -T logstash sh -c 'cat /usr/share/logstash/data/dead_letter_queue/main/*.log 2>/dev/null | grep -a -c BAD-MAPPING' | tr -d '[:space:]')
if [ "${dlq:-0}" -ge 1 ] 2>/dev/null; then echo "PASS  mapping error is in the dead letter queue"; else echo "FAIL  mapping error is not in the dead letter queue (found '${dlq:-}')"; fail=1; fi

exit $fail
