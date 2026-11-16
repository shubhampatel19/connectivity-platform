# Connectivity: architecture

This is the map of the whole system: what each part is for, how data moves, what each hop guarantees, and where it is designed to bend when something fails. Each component repo has its own `docs/DESIGN.md` for the code inside it.

## What the system does

Field devices at customer sites send hardware telemetry to a cloud backend, raise alerts when their hardware faults, and upload log bundles for support. The cloud stores the telemetry, turns alerts into support cases, and writes a triage note for each case. It is modelled on a real product shape: an embedded agent on each device, an optional gateway at the customer's site, and a vendor cloud.

```
 EDGE                                             CLOUD
 site A (200 devices)        WAN site-a
┌──────────────┐  ─────────────────────────▶ ┌────────────┐      ┌─────────┐      ┌─────────────────────┐     ┌──────────┐
│ edge-agent   │                             │ ingest-api │ ───▶ │  Kafka  │ ───▶ │ telemetry-processor │ ──▶ │ Postgres │
└──────────────┘                             │            │      │         │      └─────────────────────┘     │          │
 site B (100 devices)        WAN site-b      │            │      │         │      ┌─────────────────────┐     │          │
┌──────────────┐  ┌──────────────┐ ────────▶ │            │      │         │ ───▶ │ case-service        │ ──▶ │          │
│ edge-agent   │─▶│ site-gateway │           └─────┬──────┘      └─────────┘      └──────────▲──────────┘     └──────────┘
└──────────────┘  └──────────────┘                 │ bundles                                 │ /v1/cases
                                             ┌─────▼──────┐                       ┌──────────┴──────────┐
                                             │ SeaweedFS  │ ◀──────────────────── │ ai-triage           │
                                             └────────────┘       reads bundles   └─────────────────────┘

 Prometheus scrapes everything ─▶ alert rules ─▶ Alertmanager ─▶ pager ─▶ timeline, phone
```

## Components

| Component | Language | Role | State it owns |
|---|---|---|---|
| edge-agent | Go | Simulates a site's devices: sensors, faults, alerts, log bundles | In-memory buffers; bundle spool on disk |
| site-gateway | Java 21 | Site B only: accepts the same API as the cloud, stores and forwards | Disk queue, device inventory |
| ingest-api | Go | The cloud's front door: authenticate, validate, make durable | None |
| Kafka | | The log between ingestion and processing | Topics (below) |
| telemetry-processor | Go | Kafka to Postgres: telemetry, device registry, bundle index | Schema `public` |
| case-service | Go | Alerts to support cases: rules, deduplication, case API | Schema `cases` |
| ai-triage | Python | A grounded triage note per case | Schema `triage` |
| SeaweedFS | | S3-compatible store for log bundles | Bundles, upload sessions |
| contracts, go-kit | Go | Wire formats; shared service plumbing | |
| platform (this repo) | | Compose and Kubernetes, observability, alerting, WAN, chaos, drills | |

## Kafka topics

| Topic | Key | Producer | Consumers | Partitions |
|---|---|---|---|---|
| `telemetry.raw` | device ID | ingest-api | telemetry-processor | 6 |
| `device.events` | device ID | ingest-api | telemetry-processor | 3 |
| `bundles.uploaded` | device ID | ingest-api | telemetry-processor, case-service | 3 |
| `device.alerts` | device ID | ingest-api | case-service | 3 |
| `<topic>.dlq` | as the source | the consumer that gave up | nobody (read with `make dlq`) | 1 |

Keying by device puts each device's records on one partition, in order. Consumers depend on that.

## The four data paths

**Telemetry.** A device buffers samples, batches them under a `batch_id`, and sends. The ingest API acknowledges with 202 only after Kafka has the batch with `acks=all`. The processor writes the batch marker and its samples in one transaction and commits its offset afterwards. A retry anywhere along the path carries the same `batch_id` and is stored once.

**Alerts.** A device raises an alert once, when a fault starts, under an `alert_id`, and sends alerts before telemetry. The case service records the alert and applies the rules in one transaction: attach to an open case, open a device case, or, when enough devices at a site fault together, open one site case.

**Log bundles.** A device packs its recent log, spools it to disk and uploads it in checksummed chunks; the upload session lives in the object store, so it resumes after a failure on either side. On completion the ingest API verifies the whole bundle and publishes an event; the processor indexes it and the case service attaches it to the case whose alert named it.

**Triage.** ai-triage polls the case API, reads the case's bundles from the object store, retrieves runbooks, asks the model for a structured note, and checks every quote against what the model was shown.

## What each hop guarantees

| Hop | Guarantee | How | What breaks it |
|---|---|---|---|
| Device → cloud (site A) | Delivered at least once, until the buffer overflows | Same `batch_id` on every retry; bounded ring buffer | An outage longer than the buffer; an agent restart (memory) |
| Device → gateway (site B) | 202 means on the gateway's disk | Disk queue, one file per record | Queue full (evicts oldest) |
| Gateway → cloud | In arrival order, at least once | One forwarder thread, head-of-line retry | A record the cloud rejects for good is dropped |
| ingest-api → Kafka | 202 means durable | `acks=all`; min ISR 2 of 3 in cluster mode | Fewer in-sync replicas than the minimum: writes are refused, not lost |
| Kafka → Postgres | Effectively once | Commit offset after the database commit; idempotent on `batch_id` | A batch replayed after its marker has aged out (`BATCH_ID_RETENTION`) |
| Alert → case | Exactly one decision per alert | `alert_id` primary key; one open case per subject and rule (partial unique index); advisory lock per site and rule | |

## How it bends under failure

The design choice repeated at every layer is: **buffer upstream, never block the device, bound every buffer, and count what falls off the end.**

| Failure | What absorbs it | Limit | Signal |
|---|---|---|---|
| Cloud or WAN down, site A | Device memory buffers | `BUFFER_CAPACITY` samples per device | `AgentSendFailures`, then `AgentDroppingSamples` |
| Cloud or WAN down, site B | Gateway disk queue | `QUEUE_MAX_RECORDS` / `QUEUE_MAX_BYTES` | `GatewayBacklog`, then `GatewayDroppingData` |
| Kafka down | The two above | as above | `IngestionErrorRateHigh` |
| Processor or Postgres down | Kafka | Topic retention (time and bytes) | `ConsumerLagHigh`, `ProcessorRetrying` |
| Object store down | Device bundle spools | `SPOOL_MAX_BUNDLES` | `ObjectStoreErrors`, then `BundlesEvicted` |
| A record no consumer can store | Dead-letter topic | 7 days | `DeadLettersWritten` |
| Too many requests at once | Load shedding at the ingest API | `MAX_IN_FLIGHT` | `IngestSheddingLoad` |
| Model provider down | Circuit breaker; cases wait | | `TriageCircuitOpen` |

Two things are deliberately independent. Readiness of the ingest API ignores the object store, so a log-upload outage can't take telemetry down. And the gateway's readiness ignores the cloud, because accepting data while the cloud is down is the gateway's whole purpose.

## Storage and retention

Everything that grows has a limit, and the limits are ordered so that deduplication survives:

```
TELEMETRY_RETENTION  <=  Kafka retention.ms  <  BATCH_ID_RETENTION
```

Batch markers are what make a replay a no-op. If a marker were deleted while its batch could still be replayed from Kafka, the batch would be stored twice.

| What | Compose mode | Cluster mode | Mechanism |
|---|---|---|---|
| Telemetry rows | 6h | 2h | Hourly partitions, dropped by the processor |
| Batch markers | 13h | 4h | Deleted in batches by the processor |
| Kafka topics | 12h, 256 MB a partition | 3h, 128 MB a partition | `retention.ms`, `retention.bytes` |
| Dead-letter topics | 7 days, 64 MB | same | |
| Prometheus | default | 2 days | |
| Log bundles, cases, triage notes | kept | kept | not yet bounded |

The default fleet writes about 235 MB of telemetry and 40 MB of batch markers an hour (measured), which is where the numbers above come from. Cluster mode is tighter because Postgres has a 2Gi volume there.

One consequence: the invariant `sum(ingested_batches.sample_count) = count(telemetry)` used in several drills holds only until the first telemetry partition is dropped. After that, compare over a recent window.

## Observability

| Signal | Where | Notes |
|---|---|---|
| Metrics | Prometheus, every service's `/metrics` | Same job names in both modes, so rules and dashboards are shared |
| Dashboards | Grafana | Overview; cluster dashboard in cluster mode |
| Logs | `make logs`; Loki in cluster mode | JSON, with `trace_id` |
| Traces | Tempo in cluster mode | One trace from device to Postgres or to the case, through the gateway's disk queue and Kafka headers |
| Alerts | `prometheus/alerts.yml`, `alerts-k8s.yml` | Unit-tested with promtool |

## Alerting and on call

```
Prometheus rules ─▶ Alertmanager (group, route by severity) ─▶ pager ─▶ timeline (make pages, :9099)
                                                                   └──▶ phone (NTFY_URL)
```

- `severity: page` means someone must look now. `severity: ticket` means working hours. Tickets are recorded and never sent to the phone.
- Alerts are grouped by name and site, so one failure is one notification.
- `Watchdog` always fires. Alertmanager sends it to the pager every minute; if the pager stops hearing it, the alerting pipeline is broken, and the pager's page says so.
- Every alert has a section in [`RUNBOOKS.md`](RUNBOOKS.md), and the pager links to it. CI enforces that.
- A person can add a report to the same timeline (`make report text="..."`). Some incidents have no alert, and start that way.

## Two ways to run it

| | Compose mode (`make up`) | Cluster mode (`make cluster-up`) |
|---|---|---|
| Cloud | Docker Compose | k3d: 1 server, 2 agents |
| Kafka | 1 broker | 3 brokers, RF 3, min ISR 2 |
| Services | 1 of each | 2 replicas, probes, disruption budgets, rolling deploys |
| Logs and traces | container logs | Loki, Tempo |
| Failure injection | stop, kill, WAN faults, drills | all of that plus Chaos Mesh |
| Edge and WAN | Compose | Compose, reaching the cluster through its ingress |

The edge always stays outside the cluster: a customer site is not in the vendor's cloud, and reaches it only through the WAN and the public front door.

## Sealed drills

`make drill` picks a scenario from `drills/scenarios`, waits a random time, and applies it. The first sign is a page, a ticket or a report. `make drill-ack` and `make drill-mitigated` stamp the timeline; `make drill-reveal` explains the scenario, prints time to detect, acknowledge and mitigate, undoes what is left, and writes a postmortem skeleton from [`POSTMORTEM_TEMPLATE.md`](POSTMORTEM_TEMPLATE.md).

The scenarios are mostly consequences of a change (a setting, a deploy, a topic or schema edit, a maintenance session) because that is what most real incidents are.

## What is still not like production

- No TLS anywhere, and device identity is a shared-secret token that never expires.
- One Postgres, no backups, no replica.
- Migrations run at service start with a superuser every service shares.
- No image registry, no vulnerability scanning, no canary step.
- 300 devices in two processes; no load test and no measured capacity limit.
- Kafka accepts writes from anything that can reach it.
