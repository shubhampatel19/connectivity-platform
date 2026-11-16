#!/usr/bin/env python3
"""The pager: where alerts stop being a web page you look at and become
something that reaches you.

Alertmanager posts firing and resolved alerts here. Each one is appended to
a timeline on disk, and pages (severity=page) are forwarded to a phone when
NTFY_URL is set. Tickets are recorded but never sent anywhere, the way a
ticket queue is read in working hours and a pager goes off at 3 a.m.

Reports (POST /report) are the other way incidents start: a person noticed
something the monitoring didn't. They are recorded and sent like pages.

  POST /alert          Alertmanager webhook (version 4)
  POST /watchdog       Alertmanager's always-firing heartbeat
  POST /report         {"text": "..."}: a human report
  GET  /pages          the timeline as JSON; ?since=<unix seconds> ?kind=page|ticket|report
  GET  /               the timeline as a page to keep open
  GET  /healthz, /metrics

Standard library only, so it runs in a stock Python image with no build.
"""

from __future__ import annotations

import html
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get("PAGER_DATA", "/data/pages.jsonl")
RUNBOOKS = os.environ.get(
    "RUNBOOK_BASE", "https://github.com/shubhampatel19/connectivity-platform/blob/main/docs/RUNBOOKS.md"
)
NTFY_URL = os.environ.get("NTFY_URL", "").strip()  # e.g. https://ntfy.sh/my-private-topic
MAX_KEEP = 2000

_lock = threading.Lock()
_counts = {"page": 0, "ticket": 0, "report": 0, "notify_ok": 0, "notify_failed": 0}
_last_watchdog = 0.0


def runbook_for(alertname: str) -> str:
    """Every alert has a section in docs/RUNBOOKS.md named after it; CI checks that."""
    return f"{RUNBOOKS}#{alertname.lower()}"


def entries_from_webhook(body: dict, now: float) -> list[dict]:
    """One timeline entry per alert in an Alertmanager webhook payload."""
    out = []
    for a in body.get("alerts", []):
        labels = a.get("labels", {})
        ann = a.get("annotations", {})
        name = labels.get("alertname", "unknown")
        severity = labels.get("severity", "ticket")
        out.append(
            {
                "at": now,
                "kind": "page" if severity == "page" else "ticket",
                "status": a.get("status", body.get("status", "firing")),
                "alertname": name,
                "labels": {k: v for k, v in labels.items() if k not in ("alertname", "severity")},
                "summary": ann.get("summary", ""),
                "description": ann.get("description", ""),
                "starts_at": a.get("startsAt", ""),
                "runbook": runbook_for(name),
            }
        )
    return out


def record(entries: list[dict]) -> None:
    if not entries:
        return
    with _lock:
        os.makedirs(os.path.dirname(DATA) or ".", exist_ok=True)
        with open(DATA, "a", encoding="utf-8") as f:
            for e in entries:
                f.write(json.dumps(e, sort_keys=True) + "\n")
                _counts[e["kind"]] = _counts.get(e["kind"], 0) + 1


def load(since: float = 0.0, kind: str = "") -> list[dict]:
    with _lock:
        try:
            with open(DATA, encoding="utf-8") as f:
                lines = f.readlines()[-MAX_KEEP:]
        except FileNotFoundError:
            return []
    out = []
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue  # a torn last line after a crash
        if e.get("at", 0) >= since and (not kind or e.get("kind") == kind):
            out.append(e)
    return out


def notify(e: dict) -> None:
    """Sends one page or report to the phone. Failures are counted, never raised:
    a pager that crashes because the phone service is down is worse than no pager."""
    if not NTFY_URL:
        return
    if e["kind"] == "report":
        title, text, prio = "Report", e["summary"], "high"
    else:
        resolved = e["status"] == "resolved"
        title = ("RESOLVED " if resolved else "PAGE ") + e["alertname"]
        where = " ".join(f"{k}={v}" for k, v in sorted(e["labels"].items()) if k in ("site", "job", "pod", "reason"))
        text = (e["summary"] or e["alertname"]) + (f"\n{where}" if where else "")
        prio = "default" if resolved else "urgent"
    req = urllib.request.Request(NTFY_URL, data=text.encode("utf-8"), method="POST")
    # HTTP headers are latin-1; anything else in a title would fail the send.
    req.add_header("Title", title.encode("ascii", "replace").decode("ascii"))
    req.add_header("Priority", prio)
    if e.get("runbook"):
        req.add_header("Click", e["runbook"])
    try:
        urllib.request.urlopen(req, timeout=10).read()
        with _lock:
            _counts["notify_ok"] += 1
    except Exception as err:  # noqa: BLE001 - any failure to notify is the same failure
        with _lock:
            _counts["notify_failed"] += 1
        print(f"pager: notify failed: {err}", file=sys.stderr, flush=True)


def fmt_time(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def render_html(entries: list[dict], now: float) -> str:
    age = now - _last_watchdog
    if _last_watchdog == 0:
        beat = '<b class="bad">no heartbeat from Alertmanager yet</b>'
    elif age > 180:
        beat = f'<b class="bad">last heartbeat {int(age)}s ago: the alerting pipeline is broken</b>'
    else:
        beat = f"alerting pipeline alive (heartbeat {int(age)}s ago)"
    rows = []
    for e in reversed(entries[-300:]):
        labels = " ".join(f"{html.escape(k)}={html.escape(str(v))}" for k, v in sorted(e.get("labels", {}).items()))
        name = html.escape(e.get("alertname", "report"))
        link = f'<a href="{html.escape(e["runbook"])}">{name}</a>' if e.get("runbook") else name
        rows.append(
            f'<tr class="{html.escape(e["kind"])} {html.escape(e.get("status", ""))}">'
            f"<td>{fmt_time(e['at'])}</td><td>{html.escape(e['kind'])}</td><td>{html.escape(e.get('status', ''))}</td>"
            f"<td>{link}</td><td>{html.escape(e.get('summary', ''))}</td><td>{labels}</td></tr>"
        )
    phone = "phone notifications on" if NTFY_URL else "phone notifications off (set NTFY_URL)"
    return f"""<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="10">
<title>Connectivity pager</title><style>
body{{font:14px system-ui,sans-serif;margin:24px;color:#222}} table{{border-collapse:collapse;width:100%}}
td,th{{padding:6px 10px;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}}
tr.page.firing td{{background:#fdecea}} tr.report td{{background:#fff4d6}} tr.resolved td{{color:#777}}
.bad{{color:#b00020}}</style></head><body>
<h1>Connectivity pager</h1><p>{beat} · {phone} · times are UTC · newest first</p>
<table><tr><th>When</th><th>Kind</th><th>Status</th><th>Alert (links to its runbook)</th><th>Summary</th><th>Labels</th></tr>
{''.join(rows) or '<tr><td colspan="6">Nothing yet.</td></tr>'}</table></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:  # one line per alert is enough; see record()
        pass

    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json_body(self) -> dict | None:
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n > 4 << 20:
                return None
            v = json.loads(self.rfile.read(n) or b"{}")
            return v if isinstance(v, dict) else None
        except ValueError:
            return None

    def do_POST(self) -> None:  # noqa: N802 - http.server's naming
        global _last_watchdog
        path = urllib.parse.urlparse(self.path).path
        body = self._json_body()
        if body is None:
            self._send(400, b'{"error":"body must be a JSON object"}')
            return
        now = time.time()
        if path == "/watchdog":
            _last_watchdog = now
            self._send(200, b"{}")
        elif path == "/alert":
            entries = entries_from_webhook(body, now)
            record(entries)
            for e in entries:
                print(f"pager: {e['kind']} {e['status']} {e['alertname']} {e['labels']}", flush=True)
                if e["kind"] == "page":
                    notify(e)
            self._send(200, json.dumps({"recorded": len(entries)}).encode())
        elif path == "/report":
            text = str(body.get("text", "")).strip()
            if not text:
                self._send(400, b'{"error":"text is required"}')
                return
            e = {"at": now, "kind": "report", "status": "open", "alertname": "report", "labels": {}, "summary": text[:1000]}
            record([e])
            print(f"pager: report {text[:200]!r}", flush=True)
            notify(e)
            self._send(200, b'{"recorded":1}')
        else:
            self._send(404, b'{"error":"not found"}')

    def do_GET(self) -> None:  # noqa: N802
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        now = time.time()
        if u.path == "/healthz":
            self._send(200, b"ok", "text/plain")
        elif u.path == "/pages":
            try:
                since = float(q.get("since", ["0"])[0])
            except ValueError:
                since = 0.0
            entries = load(since, q.get("kind", [""])[0])
            self._send(200, json.dumps({"pages": entries, "watchdog_age_seconds": (now - _last_watchdog) if _last_watchdog else None}).encode())
        elif u.path == "/metrics":
            with _lock:
                c = dict(_counts)
            lines = [
                "# HELP connectivity_pager_entries_total Alerts and reports recorded, by kind.",
                "# TYPE connectivity_pager_entries_total counter",
                *[f'connectivity_pager_entries_total{{kind="{k}"}} {c[k]}' for k in ("page", "ticket", "report")],
                "# HELP connectivity_pager_notifications_total Phone notifications attempted, by result.",
                "# TYPE connectivity_pager_notifications_total counter",
                f'connectivity_pager_notifications_total{{result="ok"}} {c["notify_ok"]}',
                f'connectivity_pager_notifications_total{{result="failed"}} {c["notify_failed"]}',
                "# HELP connectivity_pager_watchdog_last_seen_timestamp_seconds When Alertmanager's heartbeat last arrived.",
                "# TYPE connectivity_pager_watchdog_last_seen_timestamp_seconds gauge",
                f"connectivity_pager_watchdog_last_seen_timestamp_seconds {_last_watchdog}",
            ]
            self._send(200, ("\n".join(lines) + "\n").encode(), "text/plain; version=0.0.4")
        elif u.path == "/":
            self._send(200, render_html(load(), now).encode(), "text/html; charset=utf-8")
        else:
            self._send(404, b'{"error":"not found"}')


def main() -> None:
    port = int(os.environ.get("PAGER_PORT", "9099"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"pager: listening on :{port}, timeline at {DATA}, phone {'on' if NTFY_URL else 'off'}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
