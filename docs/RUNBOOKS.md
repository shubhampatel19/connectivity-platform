# Runbooks

One section per alert, named exactly as the alert is, so the pager can link straight to it. CI fails if an alert has no section here.

Each runbook says what the alert means, where to look first, and how to stop the damage. It does not say what the root cause is: the same alert has several, and finding which one is the job. Mitigate first, diagnose second.

**Where to look, in order:** the pager timeline (`make pages`) for what fired and when; the overview dashboard (http://localhost:3000) for which layer changed; `make ps` and `make logs s=<service>` for the service itself; `make lag`, `make topics`, `make psql` for Kafka and Postgres.

**What changed?** Ask this before anything else. `git -C ../connectivity-<repo> log -3`, `git status` in this repo, `docker compose ps` (look at the "created" column), `kubectl rollout history`. Most incidents follow a change.

---

## Ingestion

### IngestionErrorRateHigh
**Means:** more than 5% of device requests get a 5xx from the ingest API. Devices are buffering; nothing is lost yet.
**Look at:** the ingest panel by route and code. All routes failing points at Kafka or the API itself; only bundle routes points at the object store. `make logs s=ingest-api` for the reason on each 503.
**Mitigate:** restore the dependency that is failing. If only one topic fails, check that topic's configuration (`make topics`). Watch `AgentDroppingSamples`: that is when buffering becomes loss.

### IngestSheddingLoad
**Means:** the ingest API has `MAX_IN_FLIGHT` requests in progress and is refusing the rest with 503.
**Look at:** request duration by route. If requests are slow, something behind the API is slow (usually Kafka's acks). If requests are fast and it still sheds, the limit is too low for the fleet.
**Mitigate:** fix the slow dependency, or correct `MAX_IN_FLIGHT`. Do not simply raise the limit while requests are slow: that removes the protection.

### AgentSendFailures
**Means:** devices at a site can't deliver telemetry and are buffering in memory.
**Look at:** the failure reason on the edge panel. `network` or `timeout` is the link (`make wan`); `http_5xx` is the cloud; `unauthorized` is credentials.
**Mitigate:** restore the path. Work out how long the buffer lasts: `BUFFER_CAPACITY` samples per device at 9 samples every 5 seconds.

### AgentDroppingSamples
**Means:** device buffers are full and overwriting their oldest samples. This is data loss, happening now.
**Look at:** whatever is causing `AgentSendFailures`; this is its consequence.
**Mitigate:** restore delivery. The dropped samples are gone; record the window for the postmortem.

### AgentAlertsStuck
**Means:** devices have held undelivered alerts for 10 minutes. Faults are not reaching support.
**Look at:** alert send failures by reason on the edge panel. `endpoint_missing` means the cloud or gateway has no `/v1/alerts`.
**Mitigate:** restore the path. An agent restart loses the alerts in its outbox, so do not restart the agent to fix this.

### AgentAlertsDropped
**Means:** a device's alert outbox filled and it discarded alerts. Those faults will never become cases.
**Look at:** what kept alerts from being delivered (`AgentAlertsStuck` comes first).
**Mitigate:** restore delivery; list the affected devices from the agent's metrics for the postmortem.

### AlertsRejected
**Means:** the cloud is refusing device alerts as invalid.
**Look at:** `make logs s=ingest-api` at info level for the 400s and their messages. Which firmware version sends them?
**Mitigate:** if a new agent version is the cause, roll it back. Do not loosen the contract in a hurry.

## Pipeline

### ConsumerLagHigh
**Means:** the telemetry processor's consumer group is more than 2,000 records behind. Data is safe in Kafka but is not reaching Postgres.
**Look at:** `make lag`. Is the processor running, and is it a member of the group the alert watches? `ProcessorRetrying` says a dependency is failing. Lag on one partition only points at one record or one key.
**Mitigate:** restore the dependency or the processor. Lag drains without help once it can write.

### ProcessorRetrying
**Means:** the processor is retrying records in place, so a partition is blocked.
**Look at:** `make logs s=telemetry-processor` for "record failed, retrying" and its `err`. A timeout after 30 seconds means the database accepted the connection and never answered.
**Mitigate:** fix what the error names. In Postgres, `SELECT pid, state, wait_event_type, query_start, query FROM pg_stat_activity WHERE datname = 'connectivity'` shows who is waiting on whom.

### IngestToStoreSlow
**Means:** it takes more than 30 seconds (p95) from the ingest API accepting a batch to the processor storing it.
**Look at:** lag and the processor's record duration. Slow writes mean Postgres; fast writes with lag mean the processor is catching up.
**Mitigate:** usually nothing beyond what `ConsumerLagHigh` asks for.

### DeadLettersWritten
**Means:** the telemetry processor or the case service met records it can never process and copied them to a dead-letter topic. The partition is not blocked.
**Look at:** `make dlq t=<topic>` with the topic the alert names. The `x-dlq-reason` header says why, and the key is the device.
**Mitigate:** find the producer. The ingest API should have refused this record, so either something wrote to Kafka directly or validation has a gap.

### DeadLetterWriteFailing
**Means:** poison records are being skipped without reaching the dead-letter topic.
**Look at:** `make topics`: do the `.dlq` topics exist and have a leader? The consumer's log has each record's source partition and offset.
**Mitigate:** create or repair the dead-letter topics. Recover the skipped records from the source topic before retention removes them.

### RetentionStalled
**Means:** no processor replica has completed a retention pass in 30 minutes. Partitions for coming hours are not being created and old ones are not dropped.
**Look at:** `make logs s=telemetry-processor` for "retention pass failed". Is a session holding the retention lock? `SELECT * FROM pg_locks WHERE locktype = 'advisory'`.
**Mitigate:** clear what blocks it. Until then inserts land in `telemetry_default` and the database grows.

## Log bundles

### ObjectStoreErrors
**Means:** the ingest API can't read or write the object store. Telemetry is unaffected by design.
**Look at:** `make ps` for the object store; the ingest API's log for the failing operation.
**Mitigate:** restore the object store. Bundles wait in device spools; watch `BundleSpoolBacklog`.

### BundleUploadsFailing
**Means:** devices keep failing to upload bundles.
**Look at:** the upload failure reason on the edge panel, and chunk latency. Slow chunks on one site mean a thin link.
**Mitigate:** restore the path or the object store.

### BundleSpoolBacklog
**Means:** more than 50 bundles are waiting at the edge.
**Look at:** the same as `BundleUploadsFailing`. How long until `SPOOL_MAX_BUNDLES`?
**Mitigate:** restore uploads before the spool starts evicting.

### BundlesEvicted
**Means:** spools are full and discarding bundles. Support data is being lost.
**Look at:** why uploads have been failing for this long.
**Mitigate:** restore uploads. Scheduled bundles go first; alert bundles go last.

### BundleChecksumFailures
**Means:** an assembled bundle didn't match the SHA-256 its device declared.
**Look at:** which devices, and whether they share a site or a gateway. Chunk checksum failures point at the link; assembly mismatches with clean chunks point at the device or the object store.
**Mitigate:** none automatic. The device gives up on that bundle.

## Site gateway

### GatewayBacklog
**Means:** the gateway is holding records the cloud hasn't accepted. Normal during a cloud or WAN outage.
**Look at:** `make gateway`, `make wan`, the upstream outcome panel.
**Mitigate:** restore the path to the cloud. The queue is bounded; `GatewayDroppingData` is the limit.

### GatewayBacklogNotDraining
**Means:** the gateway reaches the cloud for pass-through calls, but its queue is not shrinking.
**Look at:** forward failures by reason; the gateway's log for the status the cloud returns for the head record.
**Mitigate:** depends on the status. A restart keeps the queue (it is on disk).

### GatewayDroppingData
**Means:** the gateway discarded queued records. This is data loss. `reason` says which kind: `evicted` (queue full), `rejected` (the cloud refused them), `corrupt` (unreadable file).
**Look at:** the gateway's log for the drop. For `rejected`, what status did the cloud return, and did credentials change?
**Mitigate:** for `evicted`, restore the cloud path. For `rejected`, stop the gateway from draining until the cloud accepts its records again.

### GatewayHttpSaturated
**Means:** the gateway's HTTP workers are all busy and devices are turned away.
**Look at:** upstream latency. A slow cloud holds workers on pass-through calls.
**Mitigate:** fix the slow path.

### GatewayHeapPressure
**Means:** the gateway's heap has been over 85% of `-Xmx` for 5 minutes.
**Look at:** the JVM panels: is it climbing steadily or flat and high?
**Mitigate:** a restart is safe (the queue is on disk). If it climbs again, it is a leak.

### GatewayGcTimeHigh
**Means:** the gateway spends more than 10% of its time in garbage collection.
**Look at:** heap usage alongside. High GC with a full heap is memory pressure.
**Mitigate:** as for `GatewayHeapPressure`.

### GatewayDevicesOffline
**Means:** more than 10% of the devices the gateway knows have gone silent.
**Look at:** `make devices`. Is the site B agent running?
**Mitigate:** restore the devices' path to the gateway (the site LAN, not the WAN).

## Cases

### CaseServiceLag
**Means:** the case service is behind on alerts; new faults are not becoming cases.
**Look at:** `make lag g=case-service`, `make logs s=case-service`.
**Mitigate:** restore the case service or Postgres. Alerts are safe in Kafka.

### CaseServiceRetrying
**Means:** the case service is retrying records; usually Postgres.
**Look at:** its log for the error.
**Mitigate:** as for `ProcessorRetrying`.

### CaseDecisionSlow
**Means:** more than 60 seconds (p95) from an alert reaching the cloud to a decision.
**Look at:** lag and Postgres latency.
**Mitigate:** as for `CaseServiceLag`.

### SiteCaseOpened
**Means:** many devices at one site raised the same fault together. This is about the customer's site, not the platform.
**Look at:** `make cases site=<a|b>` and the site case's devices.
**Mitigate:** nothing in the platform. Check that it really is one site-wide event and not a bad rule or a bad firmware version.

### CasesWaitingForLogs
**Means:** an open case has waited 30 minutes for the bundle its device collected.
**Look at:** the bundle ID in `make case id=N`; follow it: device spool, gateway, ingest API, object store, `bundles.uploaded`.
**Mitigate:** unblock whichever hop holds it.

### CaseGaugesStale
**Means:** the case service stopped refreshing its open-case gauges; the panels show old numbers.
**Look at:** the case service's log around the stats refresh; Postgres.
**Mitigate:** usually follows a Postgres problem.

## AI triage

### TriageBacklog
**Means:** cases with logs have waited more than 15 minutes for a note.
**Look at:** the triage outcome panel: `skipped_budget`, `skipped_breaker` or `failed`.
**Mitigate:** depends on which; see the three alerts below.

### TriageModelFailing
**Means:** more than half of model requests fail.
**Look at:** requests by outcome. `rate_limited` is concurrency, `auth` is the key, `timeout` or `server_error` is the provider, `invalid_output` is the prompt or model.
**Mitigate:** nothing if it is the provider; the breaker and retries handle it.

### TriageCircuitOpen
**Means:** the breaker is open; cases wait until the provider recovers.
**Look at:** the provider's status, and `make llm-faults` in case a drill left faults on.
**Mitigate:** none needed; notes resume when the breaker closes.

### TriageSpendRateHigh
**Means:** triage is spending faster than its daily budget allows.
**Look at:** notes per case. A case triaged again and again, or a flood of cases?
**Mitigate:** the budget stops spend within the day. Stop the cause; lower `TRIAGE_BUDGET_USD` if needed.

### TriageBudgetExhausted
**Means:** the daily budget is spent; new cases get no note.
**Look at:** what spent it (`make triages`).
**Mitigate:** raise the budget only after understanding the spend.

### TriageNotesUngrounded
**Means:** notes cite log lines, devices or runbooks the model was never given.
**Look at:** the grounding checks in `make triage id=N`.
**Mitigate:** treat notes as untrusted; run `make eval` against the current model and prompt.

### TriagePromptInjection
**Means:** a device's log contains text aimed at an AI model.
**Look at:** the note for that case: was `injection_detected` set, and did any next step follow the planted text?
**Mitigate:** nothing acts on notes automatically. Find which customer-editable field carried it.

## Platform

### TargetDown
**Means:** Prometheus can't scrape a job. Either the process is down or it never started serving metrics.
**Look at:** `make ps`, then `make logs s=<job>`. A process that is running but silent in its log is stuck in startup; see what it does before it starts serving.
**Mitigate:** depends on the job. A down exporter hides a problem; a down service is one.

### Watchdog
**Means:** nothing is wrong. This alert always fires, and is the heartbeat Alertmanager sends the pager.
**Look at:** nothing.
**Mitigate:** nothing. Never silence it.

### PagerHeartbeatLost
**Means:** the pager hasn't heard Alertmanager's heartbeat for 5 minutes. Alerts may be firing with nobody told.
**Look at:** http://localhost:9093 (is Alertmanager up, is `Watchdog` there?) and Prometheus's Status → Runtime for its Alertmanager endpoints.
**Mitigate:** restore Alertmanager. Until then, watch http://localhost:9090/alerts directly.

### PagerNotificationsFailing
**Means:** the pager couldn't send a page to the phone. The timeline still has every page.
**Look at:** `make logs s=pager`; is `NTFY_URL` right and reachable?
**Mitigate:** keep the pager's page open until it is fixed.

### PostgresDown
**Means:** the Postgres exporter can't reach the database.
**Look at:** `make ps`, `make logs s=postgres`. Everything that writes will be retrying.
**Mitigate:** restore Postgres. Nothing is lost while Kafka holds the data, up to its retention.

### PostgresDatabaseLarge
**Means:** the database is bigger than retention should allow.
**Look at:** `SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class WHERE relkind IN ('r','p') ORDER BY pg_total_relation_size(oid) DESC LIMIT 10`. Is `telemetry_default` large? Is `RetentionStalled` firing?
**Mitigate:** get retention running; lower `TELEMETRY_RETENTION` if the fleet grew.

### PostgresVolumeFillingUp
**Means:** cluster mode: Postgres is using most of its 2Gi volume. A full volume stops the database.
**Look at:** as for `PostgresDatabaseLarge`.
**Mitigate:** drop old telemetry partitions by hand if retention can't run: `DROP TABLE telemetry_pYYYYMMDDHH`.

### PostgresConnectionsNearLimit
**Means:** more than 80% of `max_connections` are in use.
**Look at:** `SELECT application_name, state, count(*) FROM pg_stat_activity GROUP BY 1, 2 ORDER BY 3 DESC`. Who holds them, and are they idle?
**Mitigate:** end the sessions that shouldn't be there (`pg_terminate_backend`); find what opened them.

### PostgresLongTransaction
**Means:** a transaction has been open for more than 5 minutes. It holds its locks and stops vacuum.
**Look at:** `SELECT pid, application_name, xact_start, state, query FROM pg_stat_activity WHERE xact_start < now() - interval '5 minutes'`, and `pg_locks` for what it holds.
**Mitigate:** if it blocks the services, `SELECT pg_terminate_backend(<pid>)`. Find out who ran it.

## Kubernetes (cluster mode)

### PodRestarting
**Means:** a container restarted several times in 10 minutes.
**Look at:** `kubectl describe pod` for the last state (OOMKilled, exit code, failed probe); the previous container's log in Loki.
**Mitigate:** depends on the reason. A crash loop after a deploy means roll back: `kubectl rollout undo`.

### ContainerOOMKilled
**Means:** a container exceeded its memory limit and was killed.
**Look at:** its memory panel against the limit: a climb is a leak, a jump is one large allocation.
**Mitigate:** it restarts by itself; find the cause before raising the limit.

### ContainerNearMemoryLimit
**Means:** a container has used over 90% of its limit for 5 minutes.
**Look at:** the trend, as above.
**Mitigate:** none yet; `ContainerOOMKilled` is next.

### CPUThrottled
**Means:** a container is throttled in over half of its scheduling periods. This looks like latency, not errors.
**Look at:** the record duration panels of the affected service.
**Mitigate:** raise the CPU request or find what is using it.

### DeploymentReplicasUnavailable
**Means:** a Deployment has had unavailable replicas for 5 minutes.
**Look at:** `kubectl get pods`: Pending means no node fits it; not ready means its readiness probe fails.
**Mitigate:** a rollout that never completes should be undone.

### StatefulSetReplicasNotReady
**Means:** Kafka or Postgres replicas aren't ready.
**Look at:** `kubectl get pods -o wide` and node status. Volumes are node-local, so a pod can't move off a lost node.
**Mitigate:** bring the node back.

### KafkaBrokerMissing
**Means:** fewer than three brokers are in the cluster.
**Look at:** `make ps`, `make topics`. With one gone, producers still work.
**Mitigate:** restore the broker before a second one goes.

### KafkaUnderReplicatedPartitions
**Means:** partitions are missing a replica. Normal while a broker catches up.
**Look at:** whether the count is falling.
**Mitigate:** none if it is falling.

### KafkaPartitionsBelowMinISR
**Means:** partitions have fewer in-sync replicas than `min.insync.replicas`. Producers with `acks=all` are refused, so devices get 503s.
**Look at:** `make topics` for the ISR of each partition, and the topic's own configuration.
**Mitigate:** restore brokers, or correct the topic's configuration if it was changed.

### KafkaPartitionOffline
**Means:** partitions have no leader. They stay offline until a broker with an in-sync copy returns.
**Look at:** which brokers held those partitions.
**Mitigate:** bring that broker back. Do not enable unclean leader election without accepting data loss.
