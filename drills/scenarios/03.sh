# shellcheck shell=bash disable=SC2034
TITLE="A deploy changed the processor's consumer group"

apply() { setenv telemetry-processor CONSUMER_GROUP=telemetry-processor-v2; }

undo() { resetenv telemetry-processor CONSUMER_GROUP; }

explain() {
  cat <<'TEXT'
What happened: a deploy set CONSUMER_GROUP=telemetry-processor-v2 on the
telemetry processor.

What it looked like: ConsumerLagHigh pages, and lag for "telemetry-processor"
grows without limit. But data is fine. The processor joined a new group,
re-read the topics from the start (all duplicates, absorbed by batch IDs) and
is keeping up. The alert watches the old group's name, and that group now has
no members, so its lag can only grow.

How to find it: the alert says the processor is behind, yet Postgres has
fresh rows and ingest-to-store latency is normal. The symptom and the data
disagree, so question the measurement. make lag shows the old group with no
active members; kafka-consumer-groups --list shows the new one. Then: what
changed? The service's environment.

How to fix it: put the setting back. The old group resumes from its old
offsets and replays what it missed as duplicates.

Worth asking: an alert tied to a name that a config change can move is
fragile. Would lag summed over every group reading the topic be better, or
worse? And what did the replay from offset 0 cost?
TEXT
}
