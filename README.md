# Connectivity

A mock edge-to-cloud telemetry system, built to break on purpose. Simulated field devices at two customer sites stream hardware telemetry to a cloud backend, raise alerts when their hardware faults, and upload log bundles for support. The cloud turns those alerts into support cases. Site A's devices talk to the cloud directly; site B's go through an on-site gateway that stores and forwards. Every layer is instrumented so you can practice diagnosing production failures using only dashboards, logs and alerts.

Both sites reach the cloud over a simulated WAN (Toxiproxy, one link per site) that you can slow down, starve, break or cut. The cloud runs in one of two modes: everything in Docker Compose (light, quick to start), or on a three-node Kubernetes cluster (k3d) with three Kafka brokers, Loki for logs and Chaos Mesh for failure injection.

In cluster mode every service is traced with OpenTelemetry, and one trace follows a telemetry batch or an alert from the device, through the site gateway's disk queue and Kafka, to Postgres or the support case.

This repo holds the local platform: the compose stack, the Kubernetes manifests, Prometheus, Grafana, Loki and Tempo config, alert rules, chaos experiments, and the workspace tooling that ties the component repos together.

```
 EDGE                                          CLOUD
 site A
┌──────────────┐     WAN link site-a     ┌────────────┐       ┌─────────┐       ┌─────────────┐      ┌──────────┐
│ edge-agent   │ ──────────────────────▶ │ ingest-api │ ────▶ │  Kafka  │ ────▶ │ telemetry-  │ ───▶ │ Postgres │
│ 200 devices  │   telemetry, alerts,    │ auth,      │ acks  │ 4 topics│ group │ processor   │ tx   │ dedup by │
│ disk spool   │   chunked bundles       │ validate   │ =all  │         │       │ at-least-1x │      │ batch_id │
└──────────────┘                         └──▲───┬─────┘       └────┬────┘       └─────────────┘      │          │
 site B                                     │   │ chunks          │ alerts,     ┌─────────────┐      │ schema   │
┌──────────────┐        ┌──────────────┐    │ ┌─▼──────────┐      └───────────▶ │ case-       │ ───▶ │ "cases"  │
│ edge-agent   │ ─────▶ │ site-gateway │ ───┘ │ SeaweedFS  │   (gateway uplink: WAN link site-b)        bundle      │ service     │      └──────────┘
│ 100 devices  │  same  │ Java 21      │      └────────────┘        events      │ rules,dedup │◀── support: /v1/cases
│              │  /v1   │ disk queue,  │                                        └─────────────┘
└──────────────┘  API   │ inventory    │
                        └──────────────┘
        └──────────────────── Prometheus scrapes everything ──── Grafana dashboard + alert rules ────────────┘
```

## Repositories

| Repo | Role | Depends on |
|---|---|---|
| [connectivity-platform](https://github.com/shubhampatel19/connectivity-platform) | Compose stack, Kubernetes manifests, WAN proxy, observability, chaos experiments, workspace tooling (this repo) | builds the services |
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
make up          # compose mode: builds images and starts 14 containers
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

The rules live in [`case-service/rules.json`](case-service/rules.json). Edit it and `make restart s=case-service` (cluster mode: `make deploy`) to change thresholds; a bad file stops the service at startup and logs every problem in it. `FAULT_RATE=0 make up` turns off spontaneous faults, so every case is one you caused.

## The WAN

Site A's devices and the site B gateway reach the cloud through `wan`, a [Toxiproxy](https://github.com/Shopify/toxiproxy) with one link per site (`site-a` on port 18080, `site-b` on 18081). Site B's devices talk to the gateway over the site LAN and never touch the WAN. Faults apply to one link and stay until you clear them, in either mode:

| Target | What the site sees |
|---|---|
| `make wan` | Each link, up or down, and the faults on it |
| `make wan-latency site=b ms=2000 [jitter=500]` | Every response from the cloud arrives that much later |
| `make wan-bandwidth site=a kbps=16` | Site-to-cloud traffic capped at 16 KB/s |
| `make wan-flaky site=a pct=30` | 30% of new connections reset by peer |
| `make wan-blackhole site=b` | Connections open, then nothing comes back; clients find out from their own timeouts |
| `make wan-down site=b` / `make wan-up site=b` | Connections refused, like a dead router |
| `make wan-clear site=b` / `make wan-reset` | One link's faults removed / everything back to normal |

The `WAN` row at the bottom of the overview dashboard shows the bytes on each link.

## Cluster mode

The same system with the cloud side on Kubernetes: a k3d cluster with one server and two agent nodes. The edge and the WAN still run in Docker Compose and reach the cluster through its ingress on host port 8080, the way a customer site reaches a real cloud.

You need Docker with about 8 GB of memory for it, [k3d](https://k3d.io) 5.7 or later, kubectl, and helm for Chaos Mesh.

```bash
make down          # if compose mode is running: both use the same ports
make cluster-up    # creates the cluster, builds and deploys the cloud, starts the edge (5 minutes or so)
make cluster-status
```

What's different from compose mode:

- **Kafka has three brokers** (KRaft, each also a controller), and every topic is replicated three ways with `min.insync.replicas=2`. One broker down is invisible to devices; two down and every produce fails.
- **Services run two replicas** behind Kubernetes Services, with readiness and liveness probes, PodDisruptionBudgets and rolling updates. The processor and the case service share their consumer groups between replicas.
- **Loki has every pod's logs**, shipped by Alloy, with the services' log level as a label and their JSON fields queryable.
- **Tempo has traces from end to end.** The edge agents, the ingest API, the processor and the case service export spans; the gateway carries each device's trace through its disk queue. Log lines written inside a trace carry its `trace_id`, and Grafana links logs and traces both ways.
- **Kubernetes state is in Prometheus**: restarts and their reasons from kube-state-metrics, CPU, memory and throttling from cAdvisor, plus cluster-only alerts (`PodRestarting`, `ContainerOOMKilled`, `KafkaPartitionsBelowMinISR`, ...) in [`prometheus/alerts-k8s.yml`](prometheus/alerts-k8s.yml).
- **Grafana has a second dashboard**, "Connectivity cluster": pods, Kafka replication, and logs.

The URLs and make targets are the same as in compose mode. `make psql`, `make lag`, `make topics`, `make stop s=kafka` and the rest use kubectl underneath; `make logs` and `make kill` also take a pod name (`make kill s=kafka-1`). For anything else, use kubectl with the cluster's context, which the scripts always name explicitly so your other clusters are never touched:

```bash
kubectl --context k3d-connectivity -n connectivity get pods -o wide
```

**Changing code.** `make deploy` rebuilds the three cloud services from the sibling repos, tags each image with its repo's commit (plus a hash of local changes, if any), imports them into the nodes and rolls them out. Because every build has its own tag, `kubectl rollout undo deployment/ingest-api` takes you back to the previous build. `make deploy` also applies any edit to `case-service/rules.json`, alert rules or dashboards; the edge picks up changes with `make edge`.

**Logs.** In Grafana, open Explore and pick Loki, or use the logs panels on the cluster dashboard:

```
{app="ingest-api"} | json | level="ERROR"
{app="telemetry-processor"} |= "retry"
sum by (app, level) (count_over_time({namespace="connectivity"}[1m]))
```

**Traces.** The agents trace one send in ten by default (`TRACE_SAMPLE_RATIO=1 make edge` for all of them), and the cloud follows each trace's decision, so a trace is either whole or absent. A telemetry trace looks like this:

```
edge-agent           send telemetry                      device.id, batch.id, buffer.samples
 └ edge-agent        POST /v1/telemetry                  (through the gateway for site B)
    └ ingest-api     POST /v1/telemetry                  gateway.id, gateway.queued_seconds
       └ ingest-api  publish telemetry.raw               waits for acks=all
          └ telemetry-processor  process telemetry.raw   outcome, retry events
             └ telemetry-processor  postgres save batch
```

The gap between `publish` and `process` is the time the record sat in Kafka. In Grafana, Explore → Tempo takes TraceQL, and the cluster dashboard has a service graph, span rates and latencies, the records the gateway held longest, and failed traces:

```
{ resource.service.name = "edge-agent" && status = error }      sends that failed at the edge
{ span.gateway.queued_seconds > 60.0 }                          records the gateway held over a minute
{ span.outcome = "duplicate" }                                  retries and replays the store absorbed
{ span.case.id = 12 }                                           the alert that opened case 12
```

TraceQL compares numbers by type, so a float attribute needs a float literal: `> 60.0` matches, `> 60` silently doesn't. Traced responses from the ingest API carry `X-Trace-ID`.

**Chaos.** `make chaos-install` adds [Chaos Mesh](https://chaos-mesh.org) (dashboard on http://localhost:2333). The experiments are in [`k8s/chaos`](k8s/chaos), each with a comment saying what to expect:

```bash
make chaos-ls                     # experiments, and what's running now
make chaos e=kafka-broker-kill    # start one
make chaos-stop                   # end everything now
```

`make cluster-down` deletes the cluster and the edge with all their data.

**If a pod dies with "too many open files"** on a Linux host, that's not a file descriptor limit. Every k3d node shares the host's kernel and its per-user inotify limits, and Ubuntu's default of 128 inotify instances runs out once Prometheus, Grafana, Loki, Alloy and Chaos Mesh are all watching files. Chaos Mesh's controller is usually the first to fail. `make cluster-up` warns when the limit is low; the fix is `sudo sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=524288`. CI hit exactly this.

## Warm-up drills

These are known failures, run before the sealed bug drills, to learn what normal and broken look like on the dashboard. For each one, predict what you'll see before you trigger it, then check your prediction.

### The cloud (either mode)

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

### The WAN (either mode)

**12. A slow link.** `make wan-latency site=b ms=3000`. Site B's devices notice nothing, because the gateway answers them locally. The gateway forwards on one thread, so 3 seconds per request caps how fast it can move data, and `GatewayBacklog` follows. Then `make wan-latency site=a ms=3000` and compare: site A's send latency jumps, but nothing fails yet. Question to answer: at what latency does site A start failing (`HTTP_TIMEOUT` is 10s), and what do the devices do then? `make wan-reset` when done.

**13. A thin pipe.** Start the edge with `BUNDLE_INTERVAL=1m` (`make up`, or `make edge` in cluster mode), then `make wan-bandwidth site=a kbps=16`. Telemetry and log bundles now share 16 KB/s. Bundles have their own capped worker pool at the edge, but not their own link. Watch telemetry send latency against bundle chunk latency. Question to answer: should the agent hold bundles back when telemetry gets slow, and what would that cost a support engineer waiting for logs?

**14. A link that drops connections.** `make wan-flaky site=a pct=30`. Nearly every send still succeeds on a retry, so look at the failure reasons on the edge panel, not the totals. Check that no batch was stored twice with the sample-count query from drill 3.

**15. A black hole versus a dead link.** `make wan-down site=b` for 2 minutes, `make wan-up site=b`, then `make wan-blackhole site=b` for 2 minutes and `make wan-clear site=b`. Both stop site B's data, but they look different on the gateway's upstream outcome panel: refused connections fail at once, a black hole costs the full `UPSTREAM_TIMEOUT` (10s) per attempt. Question to answer: during a black hole, how long does the gateway take to notice, and which of its alerts fires first?

### Cluster mode

Run `make chaos-install` first. Predict which alerts fire, in what order, before each one.

**16. Lose a broker.** `make chaos e=kafka-broker-kill`. `KafkaBrokerMissing` may fire for a moment, under-replicated partitions rise and fall on the cluster dashboard, and devices see nothing. Afterwards look at "Partition leaders per broker". Question to answer: why does the broker that came back lead nothing at first, and what moves leadership back to it?

**17. Lose two brokers.** `make chaos e=kafka-two-brokers-down` (3 minutes). Every produce now fails with `NOT_ENOUGH_REPLICAS`: the ingest API returns 503, site A buffers, the gateway queues. Find the producer errors in Loki (`{app="ingest-api"} | json | level=~"WARN|ERROR"`). Question to answer: the controllers run on the same three pods, so what happens to leader elections while two of three are gone, and what does that mean for a partition whose leader was on a failed broker?

**18. One broker cut off from the others.** `make chaos e=kafka-broker-partition` (3 minutes). kafka-2 can still talk to clients but not to its peers. It drops out of every ISR and leaders move away from it. Question to answer: what do clients get when they send to a partition kafka-2 still thinks it leads?

**19. A slow database.** `make chaos e=postgres-latency` (5 minutes). Nothing fails; consumer lag climbs and ingest-to-store latency stretches. Question to answer: is the processor's throughput now bound by Postgres round trips, and what in its code would you change to make it less sensitive to latency?

**20. Rebalance storm.** `make chaos e=processor-kill-every-minute`, wait 10 minutes, `make chaos-stop`. Each kill rebalances the consumer group. Does lag recover between kills? Was anything stored twice? (Sample-count query, drill 3.)

**21. Memory pressure.** `make chaos e=case-service-memory-pressure` (5 minutes). `ContainerNearMemoryLimit` should fire. If the kernel OOM-kills, find out which process it chose and whether the pod restarted (`kubectl describe pod`, `ContainerOOMKilled`).

**22. Lose a node.** `docker stop k3d-connectivity-agent-1` for 10 minutes, then `docker start` it. Watch `make cluster-status`. Stateless pods move after Kubernetes gives up on the node (about 5 minutes); a broker or database whose node-local volume is on that node can't move and stays Pending. Question to answer: what was degraded during those first 5 minutes, and which alert told you?

**23. Deploys and rollbacks.** CI proves that a rolling restart of the ingest API costs devices nothing. Find out why: remove the `preStop` sleep from [`k8s/cloud/ingest-api.yaml`](k8s/cloud/ingest-api.yaml), `make deploy`, then `kubectl --context k3d-connectivity -n connectivity rollout restart deployment/ingest-api` a few times while watching the edge send failure panel. Then make a visible change in the ingest API, `make deploy`, and roll it back with `kubectl rollout undo`.

**24. Follow one record through an outage.** `make wan-down site=b` for 2 minutes, then `make wan-up site=b`. On the cluster dashboard, "Records the gateway held" lists the backlog. Open the longest: the device's send and the ingest API's span sit in one trace minutes apart, with `gateway.queued_seconds` on the ingest span. Then find the same batch in Postgres by its `batch.id`. Question to answer: the device's own send span is short and succeeded, yet the data arrived minutes later; what in the trace tells a support engineer the data was never at risk?

**25. Find the slow hop.** Run drill 19 (`make chaos e=postgres-latency`) again, but start from the traces this time: the p95 span duration panel, then one slow trace. Which span grew, and which didn't? Repeat with `make chaos e=ingest-kafka-packet-loss` and compare where the time goes.

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
- **The edge stays outside the cluster.** Customer sites don't run in the vendor's cloud. The edge reaches the cluster only through the WAN proxy and the public ingress, so a WAN fault or a cloud fault looks to devices exactly as it would in the field.
- **Three brokers, min ISR 2, acks=all.** The smallest Kafka cluster that survives losing a broker without losing acknowledged data. Losing two stops writes rather than risking data, which the devices' buffers and the gateway's queue are there to absorb.
- **Pods drain before they stop.** A `preStop` sleep keeps an ingest API pod serving until the ingress has stopped sending it requests, then shutdown drains what's in flight. Without it, every deploy costs some devices a retry.
- **Every build has its own image tag.** Deploying `:latest` or `:dev` makes a rollback a guess. Tagging by commit means `rollout undo` goes to a known build.
- **Liveness and readiness are separate.** `/healthz` stays up when Kafka is down, while `/readyz` reports it. Restarting the process wouldn't fix a dependency outage.

## Roadmap

1. **Phase 1 (done): direct path.** Edge agent, ingest API, Kafka, telemetry processor, Postgres, metrics, alerts.
2. **Phase 2 (done): log bundles.** Devices collect logs on a schedule and on thermal faults, spool them to disk, and upload them in resumable, checksummed chunks to an S3-compatible object store. The processor indexes them in Postgres.
3. **Phase 3 (done): site gateway** (`connectivity-site-gateway`, Java 21). Device inventory, store-and-forward with a disk queue, a capped upstream connection pool, and JVM metrics. Site A runs direct, site B behind the gateway. CI takes the cloud down mid-run and checks that site B's data arrives with no gaps.
4. **Phase 4 (done): alerts to cases** (`connectivity-case-service`). Devices raise alerts for thermal, PSU and disk faults; the gateway stores and forwards them; a rules engine opens cases with three layers of deduplication, including one site case for a storm; log bundles attach to their cases. CI injects faults and checks the exact cases that open, an alert carried through a cloud outage, and a full replay that changes nothing.
5. **Phase 5 (done): production platform.** Cluster mode on k3d: three Kafka brokers, replicated services with probes and disruption budgets, commit-tagged rolling deploys. Toxiproxy on each site's WAN link in both modes. Chaos Mesh with eight experiments. Loki with every pod's logs, Kubernetes metrics and alerts, and OpenTelemetry tracing in every service into Tempo, with the device's trace carried through the gateway's disk queue and Kafka. CI runs the whole system on k3d and checks a WAN cut at one site, a rolling deploy, a broker killed by Chaos Mesh, and whole traces from both sites.
6. **AI triage** (`connectivity-ai-triage`). LLM summaries of the log bundle attached to each case, RAG over runbooks, and an eval suite.

After Phase 6: sealed bug drills, where a script applies a bug you haven't seen and you find it.
