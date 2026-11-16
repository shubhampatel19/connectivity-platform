# shellcheck shell=bash disable=SC2034
TITLE="A topic's durability setting was raised beyond what the cluster has"

apply() {
  kafka kafka-configs --alter --entity-type topics --entity-name telemetry.raw \
    --add-config "min.insync.replicas=$(($(brokers) + 1))" > /dev/null
}

undo() {
  kafka kafka-configs --alter --entity-type topics --entity-name telemetry.raw \
    --delete-config min.insync.replicas > /dev/null
}

explain() {
  cat <<'TEXT'
What happened: min.insync.replicas on telemetry.raw was set to one more than
the number of brokers. With acks=all, the brokers now refuse every write to
that topic (NOT_ENOUGH_REPLICAS).

What it looked like: a partial outage. Telemetry gets 503s, so
IngestionErrorRateHigh and AgentSendFailures fire. Heartbeats, alerts and
bundle events still work, because their topics are untouched. Every broker is
up, nothing is under-replicated, and the cluster-mode ISR alert stays quiet
because the replicas really are in sync.

How to find it: split the ingest errors by route: only telemetry fails. The
ingest API's log names the Kafka error. Then look at the topic, not the
brokers: make topics shows its configuration.

How to fix it: remove the override:
  kafka-configs --alter --entity-type topics --entity-name telemetry.raw --delete-config min.insync.replicas

Worth asking: topic configuration is changed by hand here and nothing records
who or when. Where should topic settings live so that a change is reviewed?
TEXT
}
