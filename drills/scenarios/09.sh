# shellcheck shell=bash disable=SC2034
TITLE="Site A's uplink was throttled"

apply() { wan bandwidth a 3; }

undo() { wan clear a; }

explain() {
  cat <<'TEXT'
What happened: site A's WAN link was capped at 3 KB/s in the site-to-cloud
direction, as if a carrier had moved the site to a backup circuit.

What it looked like: site A's sends get slow, then time out;
AgentSendFailures fires for site-a with reason "timeout", buffers fill, and
if it lasts, AgentDroppingSamples. Site B is untouched. The cloud is healthy
and so are the devices.

How to find it: one site, timeouts not errors, cloud-side request durations
normal for the requests that do arrive. That points between the site and the
cloud. make wan shows the link; the WAN row on the dashboard shows bytes
through each link flat-lining at a low ceiling.

How to fix it: here, make wan-clear site=a. In the field you can't fix a
customer's circuit, so the question becomes what the fleet should do on a
thin link.

Worth asking: telemetry and log bundles share this link. Should the agent
hold bundles back when telemetry is failing? What is the smallest bandwidth
at which a site keeps up, and how would you know a site is below it?
TEXT
}
