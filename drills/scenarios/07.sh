# shellcheck shell=bash disable=SC2034
TITLE="A rules change stopped overheating devices from opening cases"
MODES="compose"

apply() {
  python3 - <<'PY'
import json
p = "case-service/rules.json"
d = json.load(open(p))
for r in d["rules"]:
    if r["id"] == "thermal-critical":
        r["min_value"] = 150
json.dump(d, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
  restart case-service
  sleep 20
  fault_unless_selftest thermal a 3
  report_later 300 "Support: three site A devices overheated a few minutes ago (the devices themselves show the fault). No case was opened for any of them."
}

undo() {
  git checkout -- case-service/rules.json
  restart case-service
}

explain() {
  cat <<'TEXT'
What happened: case-service/rules.json was edited to give the thermal rule
min_value 150, and the case service was restarted to pick it up. No CPU
reaches 150 degrees, so thermal alerts are recorded as below_threshold and no
case opens. Three devices then overheated.

What it looked like: nothing. Every service is healthy, every alert is
quiet, alerts flow, and the case service processes them without error. The
system did exactly what it was configured to do. The first signal was a
person in support.

How to find it: follow one fault. make answers shows the devices that
faulted; cases.alerts has their alerts with outcome below_threshold;
make rules shows what the case service is running with; git status and
git diff in this repo show the edit.

How to fix it: revert the file, restart the case service. Alerts that were
already decided stay decided: the three faults still have no case. Would you
replay them (make replay)? What does a replay do to cases that are open?

Worth asking: a wrong business rule fails silently. What would notice
"alerts are arriving and none open cases"? And why could this file change
with no review and no test?
TEXT
}
