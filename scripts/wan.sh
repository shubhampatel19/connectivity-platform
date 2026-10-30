#!/usr/bin/env bash
# Breaks the WAN between a site and the cloud. Each site has its own link in
# the Toxiproxy container "wan": site-a carries site A's devices, site-b
# carries the site B gateway's uplink (its devices are on the site LAN and
# never touch the WAN). Works the same in compose and cluster mode.
#
#   wan.sh show
#   wan.sh latency   <a|b> <ms> [jitter_ms]   added to every response from the cloud
#   wan.sh bandwidth <a|b> <KB/s>             caps the site-to-cloud direction
#   wan.sh flaky     <a|b> <percent>          resets that share of new connections
#   wan.sh blackhole <a|b>                    accepts connections, then delivers nothing:
#                                             clients only find out from their own timeouts
#   wan.sh down      <a|b>                    refuses connections, like a dead router
#   wan.sh up        <a|b>                    undoes down
#   wan.sh clear     <a|b>                    removes that link's toxics
#   wan.sh reset                              every link up, no toxics
set -euo pipefail

API=${WAN_API:-http://localhost:8474}

link() {
  case "${1:-}" in
    a | site-a) echo site-a ;;
    b | site-b) echo site-b ;;
    *) echo "site must be a or b" >&2; exit 2 ;;
  esac
}

# Toxics are named after their kind, so applying one again replaces it.
toxic() {
  local l=$1 name=$2 body=$3
  curl -fsS -o /dev/null -X DELETE "$API/proxies/$l/toxics/$name" 2> /dev/null || true
  curl -fsS -o /dev/null -X POST "$API/proxies/$l/toxics" -d "$body"
  echo "$l: $name on"
}

show() {
  curl -fsS "$API/proxies" | python3 -c '
import json, sys
for name, p in sorted(json.load(sys.stdin).items()):
    state = "up" if p["enabled"] else "DOWN"
    toxics = ", ".join(
        "%s(%s)" % (t["name"], " ".join("%s=%s" % kv for kv in t["attributes"].items()))
        + ("" if t.get("toxicity", 1) == 1 else " on %d%% of connections" % round(t["toxicity"] * 100))
        for t in p["toxics"]) or "none"
    print("%-7s %-5s %s -> %s   toxics: %s" % (name, state, p["listen"], p["upstream"], toxics))'
}

cmd=${1:-show}
case "$cmd" in
  show) show ;;
  latency)
    l=$(link "${2:-}"); ms=${3:?latency in ms}; jitter=${4:-0}
    toxic "$l" latency "{\"name\":\"latency\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":$ms,\"jitter\":$jitter}}" ;;
  bandwidth)
    l=$(link "${2:-}"); rate=${3:?rate in KB/s}
    toxic "$l" bandwidth "{\"name\":\"bandwidth\",\"type\":\"bandwidth\",\"stream\":\"upstream\",\"attributes\":{\"rate\":$rate}}" ;;
  flaky)
    l=$(link "${2:-}"); pct=${3:?percent of connections}
    toxicity=$(python3 -c "print(min(max(float('$pct') / 100, 0), 1))")
    toxic "$l" flaky "{\"name\":\"flaky\",\"type\":\"reset_peer\",\"stream\":\"upstream\",\"toxicity\":$toxicity,\"attributes\":{\"timeout\":0}}" ;;
  blackhole)
    l=$(link "${2:-}")
    toxic "$l" blackhole "{\"name\":\"blackhole\",\"type\":\"timeout\",\"stream\":\"upstream\",\"attributes\":{\"timeout\":0}}" ;;
  down)
    l=$(link "${2:-}"); curl -fsS -o /dev/null -X POST "$API/proxies/$l" -d '{"enabled":false}'; echo "$l: down" ;;
  up)
    l=$(link "${2:-}"); curl -fsS -o /dev/null -X POST "$API/proxies/$l" -d '{"enabled":true}'; echo "$l: up" ;;
  clear)
    l=$(link "${2:-}")
    for t in latency bandwidth flaky blackhole; do
      curl -fsS -o /dev/null -X DELETE "$API/proxies/$l/toxics/$t" 2> /dev/null || true
    done
    echo "$l: no toxics" ;;
  reset) curl -fsS -o /dev/null -X POST "$API/reset"; echo "every link up, no toxics" ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
