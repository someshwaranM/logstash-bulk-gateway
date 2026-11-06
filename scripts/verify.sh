#!/usr/bin/env bash
# Checks the end state after sending sample/bulk-acme.ndjson as tenant "acme".
set -uo pipefail

ES="http://localhost:9200"
AUTH="elastic:${ELASTIC_PASSWORD:-changeme}"
IDX="orders-acme"
fail=0

check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi
}

curl -s -u "$AUTH" -X POST "$ES/$IDX/_refresh" >/dev/null

doc1=$(curl -s -u "$AUTH" "$ES/$IDX/_doc/1")
if [ "$(echo "$doc1" | jq -r '.found')" != "true" ]; then
  echo "FAIL  doc 1 does not exist. Did ./scripts/send.sh run, and has Logstash had a few seconds to process it?"
  exit 1
fi
check "doc 1 exists"               "true"           "$(echo "$doc1" | jq -r '.found')"
check "doc 1 was updated (total)"  "45"             "$(echo "$doc1" | jq -r '._source.total | floor')"
check "doc 1 email is masked"      "j***@example.com" "$(echo "$doc1" | jq -r '._source.email')"
check "doc 1 has no nested 'doc'"  "null"           "$(echo "$doc1" | jq -r '._source.doc')"
check "doc 2 was deleted"          "404"            "$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$ES/$IDX/_doc/2")"
check "doc 3 (debug) was dropped"  "404"            "$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$ES/$IDX/_doc/3")"

exit $fail
