#!/usr/bin/env bash
# Operates the cloud services the same way in both modes. In compose mode
# they are Compose services. In cluster mode (`make cluster-up` writes
# "cluster" to .mode) they run on k3d, while the edge services (edge-agent,
# edge-agent-site-b, site-gateway, wan) are still Compose.
#
#   cloud.sh sql "SELECT ..."             one query, bare output (for scripts)
#   cloud.sh query "SELECT ..."           one query, as a table
#   cloud.sh psql                         interactive psql
#   cloud.sh kafka <tool> [args...]       a Kafka CLI tool, e.g. kafka-topics --describe,
#                                         run inside a broker against localhost:9092
#   cloud.sh stop|start|restart|kill|logs <service-or-pod>
#   cloud.sh ps
#   cloud.sh replay                       reprocess every alert from offset 0
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=$(cat .mode 2> /dev/null || echo compose)
CONTEXT=k3d-connectivity
NS=connectivity
EDGE=" edge-agent edge-agent-site-b site-gateway wan "

compose() {
  if [ "$MODE" = cluster ]; then
    COMPOSE_PROFILES='' WAN_UPSTREAM=host.docker.internal:8080 docker compose "$@"
  else
    COMPOSE_PROFILES=cloud docker compose "$@"
  fi
}
k() { kubectl --context "$CONTEXT" -n "$NS" "$@"; }
on_cluster() { [ "$MODE" = cluster ] && [[ "$EDGE" != *" $1 "* ]]; }
tty() { if [ -t 0 ] && [ -t 1 ]; then echo "-it"; else echo "-i"; fi; }

# A broker that is up and ready (any of them will do for admin tools).
broker() {
  k get pods -l app=kafka --no-headers \
    -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready' \
    | awk '$2 == "true" && !found {print $1; found = 1}'
}

# deployment/x or statefulset/x for a service name.
workload() {
  if k get deployment "$1" > /dev/null 2>&1; then echo "deployment/$1"
  elif k get statefulset "$1" > /dev/null 2>&1; then echo "statefulset/$1"
  else echo "no deployment or statefulset named $1" >&2; exit 1; fi
}

psql_args=(psql -U connectivity -d connectivity)

sql() {
  if [ "$MODE" = cluster ]; then k exec postgres-0 -- "${psql_args[@]}" -tAc "$1"
  else compose exec -T postgres "${psql_args[@]}" -tAc "$1"; fi
}

query() {
  if [ "$MODE" = cluster ]; then k exec postgres-0 -- "${psql_args[@]}" -c "$1"
  else compose exec -T postgres "${psql_args[@]}" -c "$1"; fi
}

psql_shell() {
  if [ "$MODE" = cluster ]; then k exec "$(tty)" postgres-0 -- "${psql_args[@]}"
  else compose exec postgres "${psql_args[@]}"; fi
}

kafka() {
  local tool=$1; shift
  if [ "$MODE" = cluster ]; then
    local b; b=$(broker)
    [ -n "$b" ] || { echo "no Kafka broker is ready" >&2; exit 1; }
    k exec "$b" -- "/opt/kafka/bin/$tool.sh" --bootstrap-server localhost:9092 "$@"
  else
    compose exec -T kafka "/opt/kafka/bin/$tool.sh" --bootstrap-server localhost:9092 "$@"
  fi
}

# Stop scales to zero and remembers the replica count; start restores it.
# `make deploy` also restores every workload to its manifest's count.
stop() {
  on_cluster "$1" || { compose stop "$1"; return; }
  local w; w=$(workload "$1")
  k annotate --overwrite "$w" connectivity/replicas="$(k get "$w" -o jsonpath='{.spec.replicas}')" > /dev/null
  k scale "$w" --replicas=0
}

start() {
  on_cluster "$1" || { compose start "$1"; return; }
  local w n; w=$(workload "$1")
  n=$(k get "$w" -o jsonpath='{.metadata.annotations.connectivity/replicas}')
  k scale "$w" --replicas="${n:-1}"
}

restart() {
  on_cluster "$1" || { compose restart "$1"; return; }
  local w; w=$(workload "$1")
  k rollout restart "$w" && k rollout status "$w" --timeout=5m
}

# A hard kill. In cluster mode `s` can be a service (every pod of it) or one
# pod (kafka-1). The pod object is deleted without waiting for the process
# to exit, which on a real cluster can leave two copies of a StatefulSet pod
# running for a moment: fine here, dangerous in production.
kill_svc() {
  on_cluster "$1" || { compose kill -s SIGKILL "$1"; return; }
  if k get pod "$1" > /dev/null 2>&1; then
    k delete pod "$1" --grace-period=0 --force
  else
    k delete pod -l app="$1" --grace-period=0 --force
  fi
}

logs() {
  on_cluster "$1" || { compose logs -f --tail=100 "$1"; return; }
  if k get pod "$1" > /dev/null 2>&1; then
    k logs -f --tail=100 "$1"
  else
    k logs -f --tail=100 --prefix --max-log-requests=10 -l app="$1"
  fi
}

ps_all() {
  if [ "$MODE" = cluster ]; then
    echo "--- cloud (k3d)"; k get pods -o wide
    echo "--- edge (compose)"
  fi
  compose ps
}

replay() {
  stop case-service
  # The reset needs the group empty; a member that hasn't left yet makes it fail.
  local ok=""
  for _ in $(seq 1 12); do
    if kafka kafka-consumer-groups --group case-service --reset-offsets --to-earliest --all-topics --execute; then ok=1; break; fi
    sleep 5
  done
  start case-service
  [ -n "$ok" ] || { echo "could not reset the case-service offsets" >&2; exit 1; }
}

verb=${1:-}; shift || true
case "$verb" in
  sql) sql "$1" ;;
  query) query "$1" ;;
  psql) psql_shell ;;
  kafka) kafka "$@" ;;
  stop) stop "$1" ;;
  start) start "$1" ;;
  restart) restart "$1" ;;
  kill) kill_svc "$1" ;;
  logs) logs "$1" ;;
  ps) ps_all ;;
  replay) replay ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
