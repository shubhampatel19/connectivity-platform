# shellcheck shell=bash disable=SC2034
TITLE="Someone tuned a timeout"

apply() { setenv ingest-api PRODUCE_TIMEOUT=2ms; }

undo() { resetenv ingest-api PRODUCE_TIMEOUT; }

explain() {
  cat <<'TEXT'
What happened: PRODUCE_TIMEOUT on the ingest API was set to 2ms (it was 5s).
The producer waits up to 5ms to batch records, so no publish can ever finish
in time.

What it looked like: every device request that publishes gets a 503.
IngestionErrorRateHigh and AgentSendFailures fire, site A buffers, the site B
gateway queues. It looks exactly like a Kafka outage, and Kafka is healthy:
/readyz is 200, make topics is clean, the brokers' logs are quiet.

How to find it: the ingest API's log says "kafka produce failed" with a
deadline error on every request, at once, with no latency building up first.
A dependency that is slow fails gradually; a limit that is wrong fails
completely and immediately. Then: what changed on ingest-api?

How to fix it: restore the setting. Devices and the gateway drain.

Worth asking: should the service refuse to start with a timeout shorter than
its own linger? Which settings deserve a sanity check at startup?
TEXT
}
