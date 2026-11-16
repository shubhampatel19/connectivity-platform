#!/usr/bin/env bash
# Sealed drills: an incident you didn't cause on purpose and don't know the
# cause of. A scenario is picked at random, applied after a random delay, and
# the first you hear of it is a page, a ticket, or a report from a person.
#
#   drill.sh start [n]      arm a drill (a random one you haven't done, or number n)
#   drill.sh status         how long it has been armed; nothing about what it is
#   drill.sh ack            "I've seen it and I'm on it": stamps the timeline
#   drill.sh mitigated      "the damage has stopped": stamps the timeline
#   drill.sh reveal         what it was, the timeline, and a postmortem to fill in;
#                           undoes whatever is still broken
#   drill.sh abort          undo it without being told what it was
#   drill.sh list           how many scenarios there are and which you've done
#   drill.sh selftest       apply and undo every scenario once (CI)
#
# DRILL_DELAY="60 600" sets the range, in seconds, of the wait before the
# fault is applied. The scenarios are in drills/scenarios. Reading them
# spoils them.
set -euo pipefail
cd "$(dirname "$0")/.."

STATE=.drills
CUR=$STATE/current
CLOUD=./scripts/cloud.sh
WAN=./scripts/wan.sh
MODE=$($CLOUD mode)

now() { date +%s; }
stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S UTC' 2> /dev/null || date -u -r "$1" '+%Y-%m-%d %H:%M:%S UTC'; }
dur() { # seconds as "4m 07s"
  local s=$1
  if [ "$s" -lt 0 ]; then echo "n/a"; else printf '%dm %02ds' $((s / 60)) $((s % 60)); fi
}
get() { cat "$CUR/$1" 2> /dev/null || true; }
put() { mkdir -p "$CUR" && printf '%s\n' "$2" > "$CUR/$1"; }
active() { [ -f "$CUR/id" ]; }
all_ids() { find drills/scenarios -name '[0-9][0-9].sh' | sed 's#.*/##; s#\.sh$##' | sort; }

# ---- what scenarios may use ----
sql() { $CLOUD sql "$1"; }
bgsql() { $CLOUD bgsql "$1"; }
setenv() { $CLOUD setenv "$1" "$2"; }
resetenv() { $CLOUD resetenv "$1" "$2"; }
kafka() { $CLOUD kafka "$@"; }
kafka_in() { $CLOUD kafka-in "$@"; }
restart() { $CLOUD restart "$1" > /dev/null 2>&1; }
kill_svc() { $CLOUD kill "$1" > /dev/null 2>&1; }
wan() { $WAN "$@" > /dev/null; }
report() { $CLOUD pager POST /report "$(python3 -c 'import json, sys; print(json.dumps({"text": sys.argv[1]}))' "$1")" > /dev/null; }
fault() { # fault <kind> <site a|b> <count>
  local port=9102
  [ "$2" = b ] && port=9103
  curl -fsS -X POST "localhost:$port/debug/faults?kind=$1&devices=$3" > /dev/null
}
# A person's report, some time after the fault: the way incidents start when
# no alert covers them. Skipped in the self-test, and if the drill has been
# aborted by the time it is due.
report_later() {
  [ -z "${DRILL_SELFTEST:-}" ] || return 0
  local id
  id=$(get id)
  (sleep "$1" && [ "$(get id)" = "$id" ] && report "$2") > /dev/null 2>&1 &
}
# Real faults on real devices are part of some scenarios, but not of the
# self-test, which must leave no cases behind.
fault_unless_selftest() { [ -n "${DRILL_SELFTEST:-}" ] || fault "$@"; }
brokers() { if [ "$MODE" = cluster ]; then echo 3; else echo 1; fi; }

# Loads scenario $1: sets TITLE, MODES, SIGNAL and defines apply, undo, explain.
load() {
  local f="drills/scenarios/$1.sh"
  [ -f "$f" ] || { echo "no scenario $1" >&2; exit 1; }
  TITLE="" MODES="compose cluster"
  # shellcheck disable=SC1090
  . "$f"
}
supports_mode() { case " $MODES " in *" $MODE "*) return 0 ;; *) return 1 ;; esac; }

pick() {
  local id candidates=()
  for id in $(all_ids); do
    grep -qx "$id" "$STATE/done" 2> /dev/null && continue
    (load "$id" && supports_mode) && candidates+=("$id")
  done
  if [ ${#candidates[@]} -eq 0 ]; then
    echo "you have done every scenario for $MODE mode; starting over" >&2
    rm -f "$STATE/done"
    for id in $(all_ids); do (load "$id" && supports_mode) && candidates+=("$id"); done
  fi
  echo "${candidates[RANDOM % ${#candidates[@]}]}"
}

start() {
  active && { echo "a drill is already armed; finish it with: make drill-reveal (or make drill-abort)" >&2; exit 1; }
  $CLOUD pager GET /healthz > /dev/null 2>&1 || { echo "the pager isn't running, so nothing could tell you about an incident; start the stack first" >&2; exit 1; }
  mkdir -p "$STATE"
  local id=${1:-}
  [ -n "$id" ] || id=$(pick)
  (load "$id" && supports_mode) || { echo "scenario $id doesn't run in $MODE mode" >&2; exit 1; }
  # shellcheck disable=SC2086
  set -- ${DRILL_DELAY:-60 600}
  local lo=$1 hi=${2:-$1}
  local delay=$((lo + RANDOM % (hi - lo + 1)))
  put id "$id"
  put armed_at "$(now)"
  nohup "$0" _inject "$id" "$delay" > "$CUR/inject.log" 2>&1 &
  echo "A drill is armed. Something will go wrong between $((lo / 60)) and $(((hi + 59) / 60)) minutes from now."
  echo "You'll find out the way on-call does: a page, a ticket, or someone telling you (make pages)."
  echo "When you notice: make drill-ack.  When the damage has stopped: make drill-mitigated.  Then: make drill-reveal."
}

inject() {
  local id=$1 delay=$2
  sleep "$delay"
  active && [ "$(get id)" = "$id" ] || exit 0 # aborted while waiting
  load "$id"
  put injected_at "$(now)"
  apply
  put applied 1
}

status() {
  active || { echo "no drill is armed (make drill)"; return; }
  local t; t=$(now)
  echo "armed $(dur $((t - $(get armed_at)))) ago"
  [ -n "$(get acked_at)" ] && echo "acknowledged $(dur $((t - $(get acked_at)))) ago"
  [ -n "$(get mitigated_at)" ] && echo "marked mitigated $(dur $((t - $(get mitigated_at)))) ago"
  echo "(whether it has started yet is for you to find out: make pages)"
}

mark() {
  active || { echo "no drill is armed" >&2; exit 1; }
  [ -z "$(get "$1")" ] || { echo "already marked at $(stamp "$(get "$1")")"; return; }
  put "$1" "$(now)"
  echo "$2 at $(stamp "$(get "$1")")"
}

cleanup() { # undo scenario $1 if it was applied
  if [ -n "$(get injected_at)" ]; then
    load "$1"
    undo || echo "warning: undoing scenario $1 reported an error; check the stack" >&2
  fi
}

# The first thing the pager recorded after the fault was applied.
first_signal() {
  $CLOUD pager GET "/pages?since=$1" 2> /dev/null | python3 -c '
import json, sys
try:
    pages = json.load(sys.stdin)["pages"]
except Exception:
    sys.exit(0)
for p in pages:
    if p.get("status") in ("firing", "open"):
        print(int(p["at"]), p.get("kind", ""), p.get("alertname", ""))
        break' || true
}

reveal() {
  active || { echo "no drill is armed" >&2; exit 1; }
  local id; id=$(get id)
  local injected; injected=$(get injected_at)
  if [ -z "$injected" ]; then
    echo "The fault hasn't been applied yet. Wait for it, or make drill-abort."
    exit 1
  fi
  load "$id"
  local t acked mitigated sig sig_at="" sig_what="nothing reached the pager"
  t=$(now); acked=$(get acked_at); mitigated=$(get mitigated_at)
  sig=$(first_signal "$injected")
  if [ -n "$sig" ]; then
    sig_at=${sig%% *}
    sig_what=${sig#* }
  fi
  local ttd="n/a" tta="n/a" ttm="n/a"
  [ -n "$sig_at" ] && ttd=$(dur $((sig_at - injected)))
  [ -n "$acked" ] && [ -n "$sig_at" ] && tta=$(dur $((acked - sig_at)))
  [ -n "$mitigated" ] && ttm=$(dur $((mitigated - injected)))

  echo "=== Drill $id: $TITLE ==="
  echo
  explain
  echo
  echo "--- Timeline"
  echo "fault applied      $(stamp "$injected")"
  [ -n "$sig_at" ] && echo "first signal       $(stamp "$sig_at")  ($sig_what)"
  [ -n "$acked" ] && echo "acknowledged       $(stamp "$acked")"
  [ -n "$mitigated" ] && echo "mitigated          $(stamp "$mitigated")"
  echo "revealed           $(stamp "$t")"
  echo
  echo "time to detect     $ttd   (fault applied -> first page, ticket or report)"
  echo "time to acknowledge $tta  (first signal -> make drill-ack)"
  echo "time to mitigate   $ttm   (fault applied -> make drill-mitigated)"
  echo
  echo "--- Undoing anything still broken"
  cleanup "$id"

  mkdir -p postmortems
  local pm
  pm="postmortems/$(date -u +%Y-%m-%d)-drill-$id.md"
  sed -e "s|{{TITLE}}|$TITLE|" -e "s|{{DATE}}|$(date -u +%Y-%m-%d)|" -e "s|{{MODE}}|$MODE|" \
    -e "s|{{INJECTED}}|$(stamp "$injected")|" -e "s|{{SIGNAL}}|${sig_at:+$(stamp "$sig_at")} ($sig_what)|" \
    -e "s|{{ACKED}}|${acked:+$(stamp "$acked")}|" -e "s|{{MITIGATED}}|${mitigated:+$(stamp "$mitigated")}|" \
    -e "s|{{TTD}}|$ttd|" -e "s|{{TTA}}|$tta|" -e "s|{{TTM}}|$ttm|" docs/POSTMORTEM_TEMPLATE.md > "$pm"
  echo "$id" >> "$STATE/done"
  rm -rf "$CUR"
  echo
  echo "Postmortem to fill in: $pm"
  echo "Write it before you read the explanation again: what you thought it was, and when you knew."
}

abort() {
  active || { echo "no drill is armed"; return; }
  local id; id=$(get id)
  cleanup "$id"
  rm -rf "$CUR"
  echo "drill aborted and undone; it stays sealed for another day"
}

list() {
  local id n=0 d=0
  for id in $(all_ids); do
    n=$((n + 1))
    if grep -qx "$id" "$STATE/done" 2> /dev/null; then d=$((d + 1)); fi
  done
  echo "$n scenarios, $d done: $(tr '\n' ' ' < "$STATE/done" 2> /dev/null || true)"
}

# Applies and undoes every scenario this mode supports, with a short pause in
# between, to prove the commands work against a running stack. It doesn't
# check that the fault had its effect; CI's own steps check the system.
selftest() {
  export DRILL_SELFTEST=1
  local id failed=0
  for id in $(all_ids); do
    load "$id"
    if ! supports_mode; then echo "skip $id (not for $MODE mode)"; continue; fi
    printf 'scenario %s: apply... ' "$id"
    if ! (apply) > "/tmp/drill-$id.log" 2>&1; then echo "FAILED"; cat "/tmp/drill-$id.log"; failed=1; fi
    sleep "${SELFTEST_HOLD:-5}"
    printf 'undo... '
    if (undo) >> "/tmp/drill-$id.log" 2>&1; then echo ok; else echo "FAILED"; cat "/tmp/drill-$id.log"; failed=1; fi
  done
  return $failed
}

verb=${1:-}; shift || true
case "$verb" in
  start) start "${1:-}" ;;
  _inject) inject "$1" "$2" ;;
  _apply) load "$1" && apply ;;
  _undo) load "$1" && undo ;;
  status) status ;;
  ack) mark acked_at "acknowledged" ;;
  mitigated) mark mitigated_at "marked mitigated" ;;
  reveal) reveal ;;
  abort) abort ;;
  list) list ;;
  selftest) selftest ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
