# shellcheck shell=bash disable=SC2034
TITLE="Something is writing to Kafka without going through the front door"

apply() {
  local ts i
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for i in 1 2 3; do
    printf 'site-b-00007\t{"received_at":"%s","batch":{"batch_id":"backfill-%s-%s","device_id":"site-b-00007","samples":[{"metric":"cpu_temp\\u0000_c","value":61.5,"ts":"%s"}]}}\n' "$ts" "$(date +%s)" "$i" "$ts"
  done | kafka_in kafka-console-producer --topic telemetry.raw --property parse.key=true --property "key.separator=$(printf '\t')" > /dev/null
}

undo() { :; } # the records are already dead-lettered; there is nothing to remove

explain() {
  cat <<'TEXT'
What happened: three records were written straight into telemetry.raw,
bypassing the ingest API, with a NUL byte in a metric name. Postgres rejects
NUL in text. (Before dead-lettering existed, each of these would have been
retried forever and stalled every device on its partition.)

What it looked like: DeadLettersWritten, a ticket. No lag, no errors for
devices. Easy to wave away, and it shouldn't be.

How to find it: make dlq t=telemetry.raw shows the records, the device in the
key, and x-dlq-reason with the Postgres error. The batch IDs start with
"backfill-", which no agent produces, and the records carry no trace headers,
which every record from the ingest API does. So they didn't come through the
ingest API.

How to fix it: nothing to fix in the pipeline; it did its job. The work is
finding the writer.

Worth asking: Kafka here accepts writes from anything that can reach it. In
production, who is allowed to produce to telemetry.raw, and how is that
enforced (ACLs, network policy)? What would you do with the dead letters
once the cause is fixed?
TEXT
}
