#!/usr/bin/env python3
"""Prints the pager's timeline, oldest first: what fired, when, and where to
read about it. Reads the JSON of GET /pages on stdin.

  cloud.sh pager GET /pages | pages.py [kind]     kind: page, ticket or report
"""

import json
import sys
from datetime import datetime, timezone


def main() -> None:
    kind = sys.argv[1] if len(sys.argv) > 1 else ""
    data = json.load(sys.stdin)
    age = data.get("watchdog_age_seconds")
    if age is None:
        print("alerting pipeline: no heartbeat from Alertmanager yet")
    elif age > 180:
        print(f"alerting pipeline: BROKEN, last heartbeat {int(age)}s ago")
    else:
        print(f"alerting pipeline: alive (heartbeat {int(age)}s ago)")
    pages = [p for p in data.get("pages", []) if not kind or p.get("kind") == kind]
    if not pages:
        print("nothing recorded")
        return
    for p in pages[-60:]:
        when = datetime.fromtimestamp(p["at"], timezone.utc).strftime("%m-%d %H:%M:%S")
        labels = " ".join(f"{k}={v}" for k, v in sorted(p.get("labels", {}).items()) if k in ("site", "job", "pod", "topic", "reason"))
        name = p.get("alertname", "")
        print(f"{when}Z  {p.get('kind', ''):6} {p.get('status', ''):8} {name:30} {labels}")
        if p.get("summary"):
            print(f"{'':17}{p['summary']}")
        if p.get("runbook") and p.get("status") == "firing":
            print(f"{'':17}{p['runbook']}")


if __name__ == "__main__":
    main()
