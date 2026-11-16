# shellcheck shell=bash disable=SC2034
TITLE="A config push left a third of one site's clocks far ahead"

apply() {
  setenv edge-agent CLOCK_SKEW_MAX=40m
  report_later 240 "Customer at site A: about a third of our devices stopped showing data a few minutes ago. The rest look normal. Nothing changed on our side."
}

undo() { resetenv edge-agent CLOCK_SKEW_MAX; }

explain() {
  cat <<'TEXT'
What happened: site A's agents were restarted with CLOCK_SKEW_MAX=40m, so
each device's clock is wrong by up to 40 minutes either way. The cloud
rejects timestamps more than 10 minutes in the future, so roughly a third of
the devices have every batch refused with a 400, and the agent drops a batch
the cloud refuses for good.

What it looked like: no page. 400s are the client's fault, so the 5xx alert
stays quiet, and devices drop the data instead of buffering it, so the send
failure alert stays quiet too. The first signal was a customer.

How to find it: the report says "a third of devices at one site". In
Postgres, group last_seen or recent telemetry by device at site A: some have
gaps, some don't. The ingest panel by status code shows 400s on telemetry;
the ingest API's log (info level) gives the reason and the device. The
affected devices are the ones whose clocks are ahead.

How to fix it: correct the devices' clocks (here, put the setting back). The
rejected data is gone.

Worth asking: this was data loss with no alert. Which signal would have
caught it: a rate of 4xx by route, the agent's rejected-batch counter, or
devices whose last telemetry is older than their last heartbeat? And should a
device drop a batch on a 400 that says "timestamp in the future"?
TEXT
}
