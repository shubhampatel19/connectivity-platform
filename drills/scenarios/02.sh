# shellcheck shell=bash disable=SC2034
TITLE="A routine restart that never came back"

apply() {
  bgsql "SELECT pg_advisory_lock(727001); SELECT pg_sleep(5400) /* schema-check */"
  sleep 3
  kill_svc telemetry-processor
}

undo() {
  sql "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE query LIKE '%schema-check%' AND pid <> pg_backend_pid()" > /dev/null
}

explain() {
  cat <<'TEXT'
What happened: a session is holding the advisory lock the telemetry processor
takes before it runs its migrations (727001). Nothing was wrong until the
processor restarted. On startup it asks for that lock and waits, forever.

What it looked like: the processor is "running" (make ps says so) but serves
no metrics, because it starts its metrics server only after migrating. So
TargetDown fires for telemetry-processor, lag climbs, and its log stops after
connecting to Postgres: no error, no retry, nothing. A process that is up,
silent and doing nothing.

How to find it: the last log line tells you which startup step it is in.
  SELECT pid, application_name, query FROM pg_stat_activity WHERE wait_event_type = 'Lock';
  SELECT pid, locktype, objid, granted FROM pg_locks WHERE locktype = 'advisory';
One session has the lock granted; the processor's is waiting.

How to fix it: terminate the session holding the lock. The processor carries
on by itself.

Worth asking: a startup step that can wait forever with no log line and no
timeout is a design gap. What should Migrate do after 60 seconds? And should
liveness notice a process that never finished starting?
TEXT
}
