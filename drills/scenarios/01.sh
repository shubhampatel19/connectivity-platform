# shellcheck shell=bash disable=SC2034
TITLE="A maintenance session left a table locked"

apply() {
  bgsql "LOCK TABLE ingested_batches IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(5400) /* reindex-maint */"
}

undo() {
  sql "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE query LIKE '%reindex-maint%' AND pid <> pg_backend_pid()" > /dev/null
}

explain() {
  cat <<'TEXT'
What happened: someone opened a psql session, took an ACCESS EXCLUSIVE lock on
ingested_batches "for a quick bit of maintenance", and left it open.

What it looked like: every telemetry write waits on that lock. Each attempt
times out after 30 seconds, so the processor retries (ProcessorRetrying), lag
climbs (ConsumerLagHigh), and after a few minutes PostgresLongTransaction
fires. Devices notice nothing: Kafka absorbs it. Postgres itself looks
healthy, which is what makes this one slow to find.

How to find it: the processor's log says its statements time out. In Postgres:
  SELECT pid, state, wait_event_type, xact_start, query FROM pg_stat_activity
  WHERE datname = 'connectivity';
shows the processor's sessions waiting on a Lock, and one session that has
been in a transaction for a long time. pg_locks shows it holds the lock.

How to fix it: SELECT pg_terminate_backend(<pid>). Lag then drains unaided.

Worth asking: what would have stopped this? (lock_timeout and
idle_in_transaction_session_timeout for interactive roles; maintenance through
a reviewed script instead of a shell.)
TEXT
}
