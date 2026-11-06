#!/usr/bin/env bash
# Sends the awkward requests a real bulk client can produce and checks what the
# gateway did with each one. Run it after the stack is up.
#
# Rejected requests have to do two things: stay out of Elasticsearch, and show
# up on Logstash's stdout. Each rejection check looks for both, so a request
# that never arrived can't pass.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${LOGSTASH_PORT:-8080}"
ES="http://localhost:9200"
AUTH="elastic:${ELASTIC_PASSWORD:-changeme}"
IDX="orders-edge"
RUN="$(date +%s)"
MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NDJSON="application/x-ndjson"
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
src() { # index, id, jq filter
  curl -s -u "$AUTH" "$ES/$1/_doc/$2" | jq -r "._source | $3"
}
printed() { # 1 if a request id shows up on Logstash's stdout, otherwise 0
  [ "$(docker compose logs --since "$MARK" logstash 2>&1 | grep -c "$1")" -ge 1 ] && echo 1 || echo 0
}
flush() { # wait until everything sent so far is processed (one ordered worker)
  local id="sentinel-$RANDOM$RANDOM"
  send $NDJSON edge "edge-flush-$id" "{ \"index\": { \"_id\": \"$id\" } }"$'\n'"{ \"order_id\": \"SENTINEL\", \"total\": 1.5 }"$'\n'
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$ES/$IDX/_doc/$id")" = "200" ] && break
    sleep 1
  done
  curl -s -u "$AUTH" -X POST "$ES/orders-*/_refresh" >/dev/null
}

curl -s -u "$AUTH" -X DELETE "$ES/$IDX" >/dev/null   # start from a clean index

# ---- requests that should be stored -------------------------------------
send "application/json" edge "e-json-$RUN" $'{ "index": { "_id": "ct1" } }\n{ "order_id": "CT-1", "total": 1.5, "level": "info" }\n'
send $NDJSON edge "e-noid-$RUN"   $'{ "index": {} }\n{ "order_id": "NOID-1", "level": "info" }\n{ "index": {} }\n{ "order_id": "NOID-2", "level": "info" }\n'
send $NDJSON edge "e-fields-$RUN" $'{ "index": { "_id": "fields1" } }\n{ "order_id": "FIELDS-1", "url": "https://shop.example/cart", "host": "web-01", "event": "checkout" }\n'
send $NDJSON edge "e-tags-$RUN"   $'{ "index": { "_id": "tags-arr" } }\n{ "order_id": "TAGS-ARR", "tags": ["vip"] }\n{ "index": { "_id": "tags-str" } }\n{ "order_id": "TAGS-STR", "tags": "vip" }\n'
send $NDJSON edge "e-epoch-$RUN"  $'{ "index": { "_id": "ts-num" } }\n{ "order_id": "TS-NUM", "@timestamp": 1704067200000 }\n{ "index": { "_id": "ts-str" } }\n{ "order_id": "TS-STR", "@timestamp": "1704067200000" }\n{ "index": { "_id": "ts-iso" } }\n{ "order_id": "TS-ISO", "@timestamp": "2024-01-01T00:00:00Z" }\n'
send $NDJSON edge "e-meta-$RUN"   $'{ "index": { "_id": "meta1" } }\n{ "order_id": "META-1", "@metadata": { "index": "orders-victim", "tenant": "victim", "action": "delete", "doc_id": "boom", "reject": true } }\n'
send $NDJSON edge "e-seed-$RUN"   $'{ "index": { "_id": "upd1" } }\n{ "order_id": "UPD-1", "total": 1.5 }\n{ "index": { "_id": "ts1" } }\n{ "order_id": "TS-1", "total": 1.5 }\n'

# ---- requests that should be rejected -----------------------------------
send $NDJSON "Bad/Tenant" "e-tenant-$RUN" $'{ "index": { "_id": "bad1" } }\n{ "order_id": "INVALID-TENANT" }\n'
send $NDJSON edge "e-yesterday-$RUN" $'{ "index": { "_id": "ts-bad" } }\n{ "order_id": "TS-YESTERDAY", "@timestamp": "yesterday" }\n'
send $NDJSON edge "e-tagsobj-$RUN"   $'{ "index": { "_id": "tags-obj" } }\n{ "order_id": "TAGS-OBJ", "tags": { "tier": "gold" } }\n'
flush

# ---- updates, and a mapping error ---------------------------------------
send $NDJSON edge "e-script-$RUN" $'{ "update": { "_id": "upd1" } }\n{ "script": { "source": "ctx._source.total += 1" } }\n'
send $NDJSON edge "e-upsert-$RUN" $'{ "update": { "_id": "up-new" } }\n{ "doc": { "order_id": "UP-NEW" }, "doc_as_upsert": true }\n'
flush
ts_before=$(src $IDX ts1 '.["@timestamp"]')
send $NDJSON edge "e-ts-update-$RUN" $'{ "update": { "_id": "ts1" } }\n{ "doc": { "total": 2.5 } }\n{ "update": { "_id": "upd1" } }\n{ "doc": { "total": 9, "@timestamp": "2024-02-02T00:00:00Z" } }\n'
send $NDJSON edge "e-mapping-$RUN" "{ \"index\": { \"_id\": \"map1\" } }"$'\n'"{ \"order_id\": \"BAD-MAPPING-$RUN\", \"total\": \"not-a-number\" }"$'\n'
flush

# ---- checks -------------------------------------------------------------
check "application/json body is split into lines and indexed" "1" "$(count '{"query":{"term":{"order_id.keyword":"CT-1"}}}' $IDX)"
check "two documents without _id both get stored"           "2" "$(count '{"query":{"terms":{"order_id.keyword":["NOID-1","NOID-2"]}}}' $IDX)"
check "client fields url, host and event are kept"          "https://shop.example/cart,web-01,checkout" "$(src $IDX fields1 '[.url, .host, .event] | join(",")')"
check "client tags array is kept"                           '["vip"]' "$(src $IDX tags-arr '.tags | tojson')"
check "client tags string is kept"                          "vip" "$(src $IDX tags-str '.tags')"
check "epoch milliseconds @timestamp (number) is converted" "2024-01-01T00:00:00.000Z" "$(src $IDX ts-num '.["@timestamp"]')"
check "epoch milliseconds @timestamp (string) is converted" "2024-01-01T00:00:00.000Z" "$(src $IDX ts-str '.["@timestamp"]')"
check "ISO @timestamp is kept"                              "2024-01-01T00:00:00.000Z" "$(src $IDX ts-iso '.["@timestamp"]')"
check "client @metadata can't steer routing"                "orders-edge,404" "$(curl -s -u "$AUTH" "$ES/orders-edge/_doc/meta1" | jq -r '._index'),$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -I "$ES/orders-victim")"
check "invalid tenant is rejected and printed"              "0,1" "$(count '{"query":{"term":{"order_id.keyword":"INVALID-TENANT"}}}' 'orders-*'),$(printed "e-tenant-$RUN")"
check "unparseable @timestamp is rejected and printed"      "0,1" "$(count '{"query":{"term":{"order_id.keyword":"TS-YESTERDAY"}}}' $IDX),$(printed "e-yesterday-$RUN")"
check "tags object is rejected and printed"                 "0,1" "$(count '{"query":{"term":{"order_id.keyword":"TAGS-OBJ"}}}' $IDX),$(printed "e-tagsobj-$RUN")"
check "update with a script is rejected, document untouched" "1,none" "$(printed "e-script-$RUN"),$(src $IDX upd1 '(.script // "none")')"
check "update with doc_as_upsert is rejected, nothing created" "1,404" "$(printed "e-upsert-$RUN"),$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$ES/$IDX/_doc/up-new")"
check "update keeps the original @timestamp"                "2.5,$ts_before" "$(src $IDX ts1 '[.total, .["@timestamp"]] | join(",")')"
check "update that sends @timestamp applies it"             "9,2024-02-02T00:00:00.000Z" "$(src $IDX upd1 '[.total, .["@timestamp"]] | join(",")')"
check "mapping error is not indexed"                        "0" "$(count "{\"query\":{\"term\":{\"order_id.keyword\":\"BAD-MAPPING-$RUN\"}}}" $IDX)"
# The dead letter queue is written to disk every few seconds, so wait for it
dlq=0
for _ in $(seq 1 30); do
  dlq=$(docker compose exec -T logstash sh -c "cat /usr/share/logstash/data/dead_letter_queue/main/*.log 2>/dev/null | grep -a -c BAD-MAPPING-$RUN" | tr -d '[:space:]')
  [ "${dlq:-0}" -ge 1 ] 2>/dev/null && break
  sleep 1
done
if [ "${dlq:-0}" -ge 1 ] 2>/dev/null; then echo "PASS  mapping error is in the dead letter queue"; else echo "FAIL  mapping error is not in the dead letter queue (found '${dlq:-}')"; fail=1; fi

exit $fail
