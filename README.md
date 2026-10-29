# Connectivity

A mock edge-to-cloud telemetry system, built to break on purpose. Simulated field devices stream hardware telemetry to a cloud backend and upload log bundles for support. Every layer is instrumented so you can practice diagnosing production failures using only dashboards, logs and alerts.

This repo holds the local platform: the compose stack, Prometheus, Grafana, alert rules, and the workspace tooling that ties the component repos together.

```
 EDGE                          CLOUD
┌──────────────┐  HTTPS   ┌────────────┐       ┌─────────┐       ┌─────────────┐      ┌──────────┐
│ edge-agent   │ ───────▶ │ ingest-api │ ────▶ │  Kafka  │ ────▶ │ telemetry-  │ ───▶ │ Postgres │
│ 200 devices  │ telemetry│ auth,      │ acks  │ 3 topics│ group │ processor   │ tx   │ dedup by │
│ (goroutines) │ + chunked│ validate   │ =all  │         │       │ at-least-1x │      │ batch_id │
│ disk spool   │ bundles  └─────┬──────┘       └─────────┘       └─────────────┘      └──────────┘
└──────────────┘                │ chunks, assembled bundles
                          ┌─────▼──────┐
                          │   MinIO    │
                          └────────────┘
        └──────────── Prometheus scrapes everything ──── Grafana dashboard + alert rules ─────┘
```

## Repositories

| Repo | Role | Depends on |
|---|---|---|
| [connectivity-platform](https://github.com/spr732/connectivity-platform) | Compose stack, observability, workspace tooling (this repo) | builds the services |
| [connectivity-contracts](https://github.com/spr732/connectivity-contracts) | Wire formats: HTTP payloads, Kafka messages, topic names | — |
| [connectivity-go-kit](https://github.com/spr732/connectivity-go-kit) | Shared service plumbing: config, logging, HTTP serving, metrics | — |
| [connectivity-edge-agent](https://github.com/spr732/connectivity-edge-agent) | Simulated device fleet at the edge | contracts, go-kit |
| [connectivity-ingest-api](https://github.com/spr732/connectivity-ingest-api) | Cloud API: device auth, validation, Kafka producer | contracts, go-kit |
| [connectivity-telemetry-processor](https://github.com/spr732/connectivity-telemetry-processor) | Kafka consumer writing to Postgres; owns the DB schema | contracts, go-kit |

Services pin `contracts` and `go-kit` by version, the way independently deployed components do in a real fleet. For day-to-day work, the bootstrap script creates a `go.work` file so you can change a shared module and a service together, then release the shared module first.

## Quick start

You need Go 1.22+, Docker with Compose v2, and git.

```bash
mkdir connectivity && cd connectivity
git clone https://github.com/spr732/connectivity-platform.git
cd connectivity-platform
make bootstrap   # clones the other repos next to this one, creates ../go.work
make tidy        # generates go.sum in each module (commit these)
make test        # unit tests with the race detector, every module
make up          # builds images and starts 10 containers
```

After about a minute:

| What | Where |
|---|---|
| Grafana dashboard | http://localhost:3000 (opens on "Connectivity overview") |
| Prometheus alerts | http://localhost:9090/alerts |
| Ingest API | http://localhost:8080 (`/healthz`, `/readyz`, `/metrics`) |
| Telemetry processor metrics | http://localhost:9101/metrics |
| Edge agent metrics | http://localhost:9102/metrics |
| MinIO console | http://localhost:9001 (user `connectivity`, password `connectivity-secret`) |
| Postgres | `make psql`, or `make bundles` for the latest log bundles |

Check that data is flowing:

```sql
SELECT count(*) AS devices, max(last_seen) FROM devices;
SELECT metric, count(*), round(avg(value)::numeric, 2) FROM telemetry GROUP BY metric;
-- devices currently in an overheat episode
SELECT device_id, max(value) AS peak_c FROM telemetry
WHERE metric = 'cpu_temp_c' AND ts > now() - interval '10 minutes'
GROUP BY device_id HAVING max(value) > 80 ORDER BY peak_c DESC;
```

## Warm-up drills

These are known failures, run before the sealed bug drills, to learn what normal and broken look like on the dashboard. For each one, predict what you'll see before you trigger it, then check your prediction.

**1. Kafka outage.** `make stop s=kafka`, wait 3 minutes, then `make start s=kafka`.
The ingest API should return 503 and devices should start buffering locally. `IngestionErrorRateHigh` and `AgentSendFailures` should fire. On recovery, watch the burst while devices drain their backlog. Question to answer: at the current sample rate and `BUFFER_CAPACITY`, how long could Kafka stay down before devices start losing data?

**2. Processor outage.** `make stop s=telemetry-processor`, wait 3 minutes, then `make start s=telemetry-processor`.
Devices shouldn't notice at all, because Kafka absorbs the backlog. Consumer lag should climb until `ConsumerLagHigh` fires. Watch ingest-to-store latency spike, then recover as the processor catches up.

**3. Database outage, then a hard crash.** `make stop s=postgres` for 2 minutes, then start it again.
The processor should retry in place without skipping or losing records. Next, while traffic is flowing, run `make kill s=telemetry-processor` (SIGKILL, no clean shutdown) and let it restart. Records polled but not yet committed get replayed. The `duplicate` series on the processor panel should tick up, and the row counts should stay correct:

```sql
SELECT (SELECT sum(sample_count) FROM ingested_batches) AS expected,
       (SELECT count(*) FROM telemetry) AS actual;
```

**4. Object store outage.** Use `BUNDLE_INTERVAL=1m make up` so bundles flow constantly, then `make stop s=minio` for 5 minutes.
Telemetry should be completely unaffected, and `/readyz` should stay 200, which is a deliberate design choice (see the ingest API README). `ObjectStoreErrors` should fire, and the edge spool backlog should climb. After `make start s=minio`, the backlog should drain, alert bundles first. Question to answer: how long until the spool hits `SPOOL_MAX_BUNDLES` and `BundlesEvicted` fires?

**5. Agent crash mid-upload.** Make bundles big enough to catch in flight: `BUNDLE_INTERVAL=1m BUNDLE_TRACE_BYTES=33554432 make up`. Wait for uploads to start (the chunk latency panel moves), then `make kill s=edge-agent` and `make start s=edge-agent`. Spooled bundles should resume where they stopped. Count chunk PUTs in the ingest API logs (`LOG_LEVEL=debug`) to confirm only the missing chunks were resent.

## Design decisions that matter during incidents

- **Batch IDs are idempotency keys.** A device assigns `batch_id` once and reuses it on every retry. The processor records batch IDs in the same transaction as the samples, so retries and replays are absorbed instead of double-counted.
- **202 means durable.** The ingest API only acknowledges after Kafka acks the write with `acks=all`.
- **Commit after write.** The processor commits offsets only after Postgres commits. Crashes cause replays, never loss.
- **Poison records are skipped, transient errors are retried.** Malformed messages are logged and counted, then skipped. Database errors block the partition and retry with backoff, which preserves per-device ordering and shows up as lag.
- **Devices drop oldest data when full.** Buffers are bounded, as on real hardware with fixed memory. Drops are counted and alerted on.
- **4xx is permanent, 5xx is transient.** The agent drops a batch the backend rejects with 4xx, so one bad batch can't wedge its queue. It retries 5xx responses, timeouts and 429s.
- **The fleet is de-synchronized.** Devices start at random offsets and back off with jitter, so recovery from an outage doesn't stampede.
- **Log uploads resume, and the cloud keeps no session state in memory.** Upload sessions live in MinIO, chunks are checksummed one by one, and the assembled bundle is verified against the device's declared SHA-256 before anything is published.
- **Log bundles can't hurt telemetry.** They use a separate, capped worker pool at the edge, and the ingest API's readiness doesn't depend on MinIO.
- **Liveness and readiness are separate.** `/healthz` stays up when Kafka is down, while `/readyz` reports it. Restarting the process wouldn't fix a dependency outage.

## Roadmap

1. **Phase 1 (done): direct path.** Edge agent, ingest API, Kafka, telemetry processor, Postgres, metrics, alerts.
2. **Phase 2 (done): log bundles.** Devices collect logs on a schedule and on thermal faults, spool them to disk, and upload them in resumable, checksummed chunks to MinIO. The processor indexes them in Postgres.
3. **Site gateway** (`connectivity-site-gateway`). Device discovery, inventory, store-and-forward with a disk buffer, and a single upstream connection. Devices choose direct or gateway mode.
4. **Alerts to cases** (`connectivity-case-service`). A rules engine and a case service with deduplication.
5. **Production platform.** Move the cloud side to k3d. Add Toxiproxy on the WAN link, Chaos Mesh, Loki for logs and Tempo for traces.
6. **AI triage** (`connectivity-ai-triage`). LLM summaries of the log bundle attached to each case, RAG over runbooks, and an eval suite.

After Phase 6: sealed bug drills, where a script applies a bug you haven't seen and you find it.
