# Connectivity

A mock edge-to-cloud telemetry system, built to break on purpose. Simulated field devices at two customer sites stream hardware telemetry to a cloud backend, raise alerts when their hardware faults, and upload log bundles for support. The cloud turns those alerts into support cases. Site A's devices talk to the cloud directly; site B's go through an on-site gateway that stores and forwards. Every layer is instrumented so you can practice diagnosing production failures using only dashboards, logs and alerts.

This repo holds the local platform: the compose stack, Prometheus, Grafana, alert rules, and the workspace tooling that ties the component repos together.

```
 EDGE                                          CLOUD
 site A
┌──────────────┐          HTTPS          ┌────────────┐       ┌─────────┐       ┌─────────────┐      ┌──────────┐
│ edge-agent   │ ──────────────────────▶ │ ingest-api │ ────▶ │  Kafka  │ ────▶ │ telemetry-  │ ───▶ │ Postgres │
│ 200 devices  │   telemetry, alerts,    │ auth,      │ acks  │ 4 topics│ group │ processor   │ tx   │ dedup by │
│ disk spool   │   chunked bundles       │ validate   │ =all  │         │       │ at-least-1x │      │ batch_id │
└──────────────┘                         └──▲───┬─────┘       └────┬────┘       └─────────────┘      │          │
 site B                                     │   │ chunks          │ alerts,     ┌─────────────┐      │ schema   │
┌──────────────┐        ┌──────────────┐    │ ┌─▼──────────┐      └───────────▶ │ case-       │ ───▶ │ "cases"  │
│ edge-agent   │ ─────▶ │ site-gateway │ ───┘ │ SeaweedFS  │        bundle      │ service     │      └──────────┘
│ 100 devices  │  same  │ Java 21      │      └────────────┘        events      │ rules,dedup │◀── support: /v1/cases
│              │  /v1   │ disk queue,  │                                        └─────────────┘
└──────────────┘  API   │ inventory    │
                        └──────────────┘
        └──────────────────── Prometheus scrapes everything ──── Grafana dashboard + alert rules ────────────┘
```

## Repositories

| Repo | Role | Depends on |
|---|---|---|
| [connectivity-platform](https://github.com/shubhampatel19/connectivity-platform) | Compose stack, observability, workspace tooling (this repo) | builds the services |
| [connectivity-contracts](https://github.com/shubhampatel19/connectivity-contracts) | Wire formats: HTTP payloads, Kafka messages, topic names | — |
| [connectivity-go-kit](https://github.com/shubhampatel19/connectivity-go-kit) | Shared service plumbing: config, logging, HTTP serving, metrics | — |
| [connectivity-edge-agent](https://github.com/shubhampatel19/connectivity-edge-agent) | Simulated device fleet at the edge | contracts, go-kit |
| [connectivity-ingest-api](https://github.com/shubhampatel19/connectivity-ingest-api) | Cloud API: device auth, validation, Kafka producer | contracts, go-kit |
| [connectivity-telemetry-processor](https://github.com/shubhampatel19/connectivity-telemetry-processor) | Kafka consumer writing to Postgres; owns the DB schema | contracts, go-kit |
| [connectivity-site-gateway](https://github.com/shubhampatel19/connectivity-site-gateway) | On-site gateway (Java 21): store-and-forward, device inventory, cloud proxy | the `/v1` API |
| [connectivity-case-service](https://github.com/shubhampatel19/connectivity-case-service) | Device alerts to support cases: rules, deduplication, case API; owns schema `cases` | contracts, go-kit |

The Go services pin `contracts` and `go-kit` by version, the way independently deployed components do in a real fleet. For day-to-day work, the bootstrap script creates a `go.work` file so you can change a shared module and a service together, then release the shared module first.

## Quick start

You need Go 1.22+, Docker with Compose v2, and git. JDK 21 and Maven are optional: Docker builds the gateway, and `make test` skips it without Maven.

```bash
mkdir connectivity && cd connectivity
git clone https://github.com/shubhampatel19/connectivity-platform.git
cd connectivity-platform
make bootstrap   # clones the other repos next to this one, creates ../go.work
make test        # unit tests with the race detector, every module
make up          # builds images and starts 13 containers
```

After about a minute:

| What | Where |
|---|---|
| Grafana dashboard | http://localhost:3000 (opens on "Connectivity overview") |
| Prometheus alerts | http://localhost:9090/alerts |
| Ingest API | http://localhost:8080 (`/healthz`, `/readyz`, `/metrics`) |
| Site gateway | http://localhost:8090/gateway/v1/devices (site B inventory), `/metrics`; or `make devices` and `make gateway` |
| Telemetry processor metrics | http://localhost:9101/metrics |
| Case service | http://localhost:8085/v1/cases, `/metrics`; or `make cases`, `make case id=N`, `make rules` |
| Edge agent metrics | http://localhost:9102/metrics (site A), http://localhost:9103/metrics (site B) |
| Stored log bundles | http://localhost:8888/buckets/log-bundles/ (SeaweedFS filer browser) |
| Postgres | `make psql`, or `make bundles` for the latest log bundles |

Check that data is flowing:

```sql
SELECT site_id, count(*) AS devices, max(last_seen) FROM devices GROUP BY site_id;
SELECT metric, count(*), round(avg(value)::numeric, 2) FROM telemetry GROUP BY metric;
-- devices currently in an overheat episode
SELECT device_id, max(value) AS peak_c FROM telemetry
WHERE metric = 'cpu_temp_c' AND ts > now() - interval '10 minutes'
GROUP BY device_id HAVING max(value) > 80 ORDER BY peak_c DESC;
-- what the case service decided about every alert, by rule
SELECT coalesce(rule_id, '(none)') AS rule, outcome, count(*) FROM cases.alerts GROUP BY 1, 2 ORDER BY 1, 2;
```

## Faults, alerts and cases

Faults are rare on their own: about one overheat or PSU sag an hour across the fleet, and a few devices with slowly degrading disks. To see the alert path straight away, cause one:

```bash
make fault kind=thermal               # one random site A device overheats
make fault kind=psu site=b n=3        # three site B devices get a sagging PSU rail
make cases                            # a minute later
make case id=1                        # its alerts, its log bundle, whether the logs have arrived
make resolve id=1 why="replaced fan"
```

The rules live in [`case-service/rules.json`](case-service/rules.json). Edit it and `make restart s=case-service` to change thresholds; a bad file stops the service at startup and logs every problem in it. `FAULT_RATE=0 make up` turns off spontaneous faults, so every case is one you caused.

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

**4. Object store outage.** Use `BUNDLE_INTERVAL=1m make up` so bundles flow constantly, then `make stop s=object-store` for 5 minutes. Halfway through, `make fault kind=thermal n=5` so some alert bundles join the backlog.
Telemetry should be completely unaffected, and `/readyz` should stay 200, which is a deliberate design choice (see the ingest API README). `ObjectStoreErrors` should fire, and the edge spool backlog should climb. The five thermal cases still open, with `logs=waiting`. After `make start s=object-store`, the backlog should drain, alert bundles first, and those cases flip to `logs=attached`. Question to answer: how long until the spool hits `SPOOL_MAX_BUNDLES` and `BundlesEvicted` fires?

**5. Agent crash mid-upload.** Make bundles big enough to catch in flight: `BUNDLE_INTERVAL=1m BUNDLE_TRACE_BYTES=33554432 make up`. Wait for uploads to start (the chunk latency panel moves), then `make kill s=edge-agent` and `make start s=edge-agent`. Spooled bundles should resume where they stopped. Count chunk PUTs in the ingest API logs (`LOG_LEVEL=debug`) to confirm only the missing chunks were resent.

**6. Cloud outage, two sites, two strategies.** `make stop s=ingest-api` for 3 minutes, then `make start s=ingest-api`.
Site A's devices buffer in their own memory and `AgentSendFailures` fires for `site-a` only. Site B's devices keep getting `202` from the gateway, which queues to disk, and `GatewayBacklog` fires instead. Compare the agent buffer panel with the gateway queue panel, then watch recovery: the gateway drains on one paced thread while site A's 200 devices all drain at once. Which recovery is gentler on the cloud, and which delivers data sooner? The gateway's time-in-queue panel answers the second half.

**7. Gateway crash with a backlog.** During drill 6, while `make gateway` shows a non-empty queue, run `make kill s=site-gateway`, then `make start s=site-gateway`. The queue and inventory are on disk, so draining should resume where it stopped, with nothing lost and nothing duplicated in Postgres. Check with the sample-count query from drill 3. Question to answer: the gateway's counters reset on restart, so how would you prove from metrics alone that nothing was lost?

**8. A site-wide cooling failure.** `make fault kind=thermal site=b n=all`. Predict the cases first. Then `make cases site=b`: one site case covering all 100 devices, with the four device cases opened before the storm threshold was reached as its children. `SiteCaseOpened` fires. Resolve the site case and check that its children closed too. Question to answer: the storm is detected per Kafka record, so why can't two consumers racing on different devices each see four devices and both miss the storm? (The case service README has the answer; try to find it in the code first.)

**9. Case service outage.** `make stop s=case-service` for 5 minutes, and `make fault kind=thermal n=3` during it. The ingest API keeps accepting alerts (they're in Kafka), so the agents see nothing wrong; `CaseServiceLag` is the only signal. After `make start s=case-service`, the three cases open within seconds. The `alert to decision` panel shows how long each fault waited: that's the gap a support engineer would ask about.

**10. Replay everything.** `make replay` resets the case service to offset 0 on both of its topics. Every alert is processed again. Watch `alerts by outcome`: all `duplicate`, and `make cases status=all` shows exactly the same cases, counts and statuses as before. Then think about what would break if `alert_id` weren't stable across retries on the device.

**11. An alert through a cloud outage.** `make stop s=ingest-api`, then `make fault kind=disk site=b` and `make fault kind=disk`. The site B alert is acked by the gateway and queued on its disk; the site A one waits in the device's outbox (`AgentAlertsStuck` after 10 minutes). Restart the API and both become cases. Then repeat, but `make kill s=edge-agent` before restarting the API: the site A alert is gone for good, because the outbox is in memory. Which of the two designs would you defend to a customer?

## Design decisions that matter during incidents

- **Batch IDs are idempotency keys.** A device assigns `batch_id` once and reuses it on every retry. The processor records batch IDs in the same transaction as the samples, so retries and replays are absorbed instead of double-counted.
- **202 means durable.** The ingest API only acknowledges after Kafka acks the write with `acks=all`.
- **Commit after write.** The processor commits offsets only after Postgres commits. Crashes cause replays, never loss.
- **Poison records are skipped, transient errors are retried.** Malformed messages are logged and counted, then skipped. Database errors block the partition and retry with backoff, which preserves per-device ordering and shows up as lag.
- **Devices drop oldest data when full.** Buffers are bounded, as on real hardware with fixed memory. Drops are counted and alerted on.
- **4xx is permanent, 5xx is transient.** The agent drops a batch the backend rejects with 4xx, so one bad batch can't wedge its queue. It retries 5xx responses, timeouts and 429s.
- **The fleet is de-synchronized.** Devices start at random offsets and back off with jitter, so recovery from an outage doesn't stampede.
- **Log uploads resume, and the cloud keeps no session state in memory.** Upload sessions live in the object store, chunks are checksummed one by one, and the assembled bundle is verified against the device's declared SHA-256 before anything is published.
- **Log bundles can't hurt telemetry.** They use a separate, capped worker pool at the edge, and the ingest API's readiness doesn't depend on the object store.
- **The object store is swappable.** The ingest API speaks plain S3. The stack started on MinIO; when MinIO withdrew its community images from Docker Hub and Quay, builds broke overnight, and moving to SeaweedFS was a change to one compose service. Pin versions, and know which of your dependencies can disappear.
- **The gateway acks what it has stored, not what the cloud has.** For site B, a `202` from the gateway means "on the gateway's disk". Durability moves to the gateway, which is why its queue is bounded, alerted on, and survives restarts.
- **The gateway's readiness ignores the cloud.** Accepting data while the cloud is down is its whole purpose. A gateway pulled out of service during a cloud outage would turn a recoverable delay into data loss at the edge.
- **One forwarder thread per gateway.** It keeps site B's data in arrival order and paces a recovering cloud, at the cost of drain speed. That trade-off is visible in drill 6.
- **An alert is reported once; the cloud decides what it means.** Devices raise an alert when a fault starts (with hysteresis, so a noisy reading doesn't re-raise it) and know nothing about cases. Rules live in the cloud, so changing what opens a case doesn't need a fleet upgrade, and codes from agents newer than the rules are recorded without opening anything.
- **Deduplication is enforced by the database.** The alert ID is a primary key, one open case per device and rule is a partial unique index, and site-level storm decisions take an advisory lock. Code that checks first and then writes would race the moment there's a second consumer.
- **Alerts go first, and through the gateway they're as durable as telemetry.** Devices send queued alerts before telemetry each tick. The gateway queues alerts in the same disk queue as telemetry, so a cloud outage at site B costs no faults.
- **Logs attach whichever arrives first.** An alert names the bundle its device collected; the case service indexes bundle events itself and links them when both are present. A case waiting too long for its logs is alerted on.
- **Liveness and readiness are separate.** `/healthz` stays up when Kafka is down, while `/readyz` reports it. Restarting the process wouldn't fix a dependency outage.

## Roadmap

1. **Phase 1 (done): direct path.** Edge agent, ingest API, Kafka, telemetry processor, Postgres, metrics, alerts.
2. **Phase 2 (done): log bundles.** Devices collect logs on a schedule and on thermal faults, spool them to disk, and upload them in resumable, checksummed chunks to an S3-compatible object store. The processor indexes them in Postgres.
3. **Phase 3 (done): site gateway** (`connectivity-site-gateway`, Java 21). Device inventory, store-and-forward with a disk queue, a capped upstream connection pool, and JVM metrics. Site A runs direct, site B behind the gateway. CI takes the cloud down mid-run and checks that site B's data arrives with no gaps.
4. **Phase 4 (done): alerts to cases** (`connectivity-case-service`). Devices raise alerts for thermal, PSU and disk faults; the gateway stores and forwards them; a rules engine opens cases with three layers of deduplication, including one site case for a storm; log bundles attach to their cases. CI injects faults and checks the exact cases that open, an alert carried through a cloud outage, and a full replay that changes nothing.
5. **Production platform.** Move the cloud side to k3d. Add Toxiproxy on the WAN link, Chaos Mesh, Loki for logs and Tempo for traces.
6. **AI triage** (`connectivity-ai-triage`). LLM summaries of the log bundle attached to each case, RAG over runbooks, and an eval suite.

After Phase 6: sealed bug drills, where a script applies a bug you haven't seen and you find it.
