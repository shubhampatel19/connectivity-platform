#!/usr/bin/env python3
"""Print recent triage notes as a table: `make triages` runs it."""
import json
import sys
import urllib.error
import urllib.request

base = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8086"
try:
    with urllib.request.urlopen(base + "/v1/triage?limit=30", timeout=5) as resp:
        notes = json.load(resp)["notes"]
except (urllib.error.URLError, OSError) as e:
    sys.exit("AI triage not reachable at %s: %s" % (base, e))

print("%d recent triage notes (make triage id=N for one in full)" % len(notes))
row = "  {:>6}  {:<7} {:<22} {:<6} {:>9} {:>7}  {}"
print(row.format("case", "status", "cause", "conf.", "cost", "ms", "summary, or why there's no note"))
for n in notes:
    text = n.get("summary") or n.get("error") or ""
    print(row.format(
        "#%d" % n["case_id"], n["status"], n.get("category") or "-", n.get("confidence") or "-",
        "$%.5f" % n["cost_usd"], n["latency_ms"], text[:90] + ("…" if len(text) > 90 else "")))
