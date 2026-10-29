#!/usr/bin/env python3
"""Print the case service's cases as a table: `make cases` runs it."""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

base = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8085"
status = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "open"
site = sys.argv[3] if len(sys.argv) > 3 else ""
if site in ("a", "b"):
    site = "site-" + site

query = urllib.parse.urlencode({"status": status, "site": site, "limit": 50})
try:
    with urllib.request.urlopen(base + "/v1/cases?" + query, timeout=5) as resp:
        cases = json.load(resp)["cases"]
except (urllib.error.URLError, OSError) as e:
    sys.exit("case service not reachable at %s: %s" % (base, e))

print("%d %s cases%s" % (len(cases), status, " at " + site if site else ""))
row = "  {:>6}  {:<8} {:<8} {:<18} {:<6} {:<14} {:>6} {:>7}  {:<8} {}"
print(row.format("case", "status", "severity", "rule", "scope", "subject", "alerts", "devices", "logs", "parent"))
for c in cases:
    print(row.format(
        "#%d" % c["case_id"], c["status"], c["severity"], c["rule_id"], c["scope"],
        c.get("device_id") or c["site_id"], c["alert_count"], c["devices"], c["logs"],
        "#%d" % c["parent_case_id"] if c.get("parent_case_id") else "-"))
