# Logstash bulk gateway

A small Logstash pipeline that sits in front of Elasticsearch and accepts `_bulk` requests from a client you can't change.

The client sends a normal bulk body. Logstash does four things before anything reaches Elasticsearch:

- masks the email address in every document
- drops `debug` events
- routes each request to a per-tenant index, based on a header
- keeps the Elasticsearch credentials, so the client never sees them

This repo goes with the Elastic Search Labs article on processing Bulk API requests with Logstash.

![Architecture: a legacy client posts a bulk request to Logstash, which pairs lines, applies rules and writes to per-tenant indices in Elasticsearch](docs/architecture.png)

## What you need

- Docker with Compose v2
- `curl` and `jq`
- About 4 GB of free memory for the three containers (Elasticsearch, Logstash and Kibana)

Tested with Elasticsearch, Logstash and Kibana 9.2.0.

## Run it

Start the stack:

```sh
docker compose up -d
```

Wait until Logstash answers on its monitoring port:

```sh
curl -s localhost:9600 | jq -r .status
```

When it prints `green`, send the sample request:

```sh
./scripts/send.sh
```

Then check the result:

```sh
./scripts/verify.sh
```

You should see six `PASS` lines.

If port 8080 is already used on your machine, pick another one and use it for both steps:

```sh
export LOGSTASH_PORT=8088
docker compose up -d
./scripts/send.sh
```

## Look at the documents in Kibana

Kibana starts with the stack. It takes a minute or so the first time.

1. Open http://localhost:5601 and log in with user `elastic` and password `changeme`.
2. Go to **Discover**, and when it asks, create a data view with the index pattern `orders-*` and `@timestamp` as the time field.
3. You'll see the documents the gateway wrote. Check that `email` is masked, that `total` is 45 on `A-1001`, and that there's no document for the `debug` event.

Send the sample as another tenant and refresh Discover to see `orders-globex` show up in the same data view.

## What the sample request does

The body is [sample/bulk-acme.ndjson](sample/bulk-acme.ndjson). It has five lines, and the client doesn't tell Elasticsearch which index to use.

| Operation | What you should see afterwards |
| --- | --- |
| index doc 1 | exists, email is `j***@example.com` |
| create doc 2 | created, then deleted by the last line, so it's gone |
| index doc 3 (level `debug`) | never stored, the pipeline drops it |
| update doc 1 | `total` is 45, and there is no nested `doc` field |
| delete doc 2 | returns 404 |

Everything lands in `orders-acme`, because the script sends `X-Tenant-Id: acme`. Send the same file as another tenant and you get a second index:

```sh
./scripts/send.sh sample/bulk-acme.ndjson globex
curl -s -u elastic:changeme "localhost:9200/_cat/indices/orders-*?v"
```

## How the pairing works

A bulk body is not one JSON document. It's lines, and most operations take two of them: an action line, then a source line. Logstash's `json_lines` codec turns every line into its own event, so the link between the two is lost.

The pipeline puts it back. It keeps a small queue per request ID. An action line goes into the queue and is dropped. The next source line takes the oldest waiting action and inherits its operation and ID. A `delete` has no source line, so it skips the queue.

![Five bulk lines turn into four Elasticsearch operations using a pending queue](docs/pairing.png)

This only works if events are handled in order, one at a time. That's why [config/logstash.yml](config/logstash.yml) sets `pipeline.workers: 1` and `pipeline.ordered: true`.

## Try breaking it

Send a request without the headers:

```sh
curl -s -X POST localhost:8080/ -H 'Content-Type: application/x-ndjson' --data-binary @sample/bulk-acme.ndjson
docker compose logs logstash | grep missing_headers
```

Logstash prints the events with a `missing_headers` tag. Nothing is written to Elasticsearch.

Now try more than one worker. Set `pipeline.workers: 2` in `config/logstash.yml` and restart Logstash:

```sh
docker compose up -d --force-recreate logstash
docker compose logs logstash | grep "requires the use of a single pipeline worker"
```

Logstash refuses to start. Set it back to `1` after.

## Files

| File | What it is |
| --- | --- |
| [docker-compose.yml](docker-compose.yml) | Elasticsearch (security on), Kibana and Logstash |
| [pipeline/bulk-gateway.conf](pipeline/bulk-gateway.conf) | The whole pipeline |
| [config/logstash.yml](config/logstash.yml) | Worker and ordering settings |
| [sample/bulk-acme.ndjson](sample/bulk-acme.ndjson) | The test bulk body |
| [scripts/send.sh](scripts/send.sh) | Posts a bulk file with the two headers |
| [scripts/verify.sh](scripts/verify.sh) | Checks the final state in Elasticsearch |
| [docs/](docs) | The two diagrams as PNG, with the editable SVG sources, and the [logos](docs/logos/NOTICE.md) they use, with their source and trademark note |

## Things to know

- A `200` from Logstash means it received the body. It doesn't mean Elasticsearch indexed anything.
- One worker means this doesn't scale across CPU cores on one node. Run several independent pipelines if you need more, split by tenant.
- The password in this repo is `changeme` for both `elastic` and Kibana's service user, and TLS is off. It's for trying things out only.
- Elasticsearch ingest pipelines can mask and route bulk data too. Use those if that's all you need. This gateway makes sense when the client must not know Elasticsearch exists, or you need to enrich from other sources or write to more than one place.

## Clean up

```sh
docker compose down -v
```
