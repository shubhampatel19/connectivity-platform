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
#   cloud.sh triage-eval <provider> <n>   AI triage's evals, n runs per case
#   cloud.sh triage-faults <spec>         the fake model's faults, on every replica
#   cloud.sh pager GET|POST <path> [json] ask the pager (timeline, reports)
#   cloud.sh dlq <topic>                  read a topic's dead-letter topic, with headers
#   cloud.sh setenv <service> NAME=value  run a service with one setting changed
#   cloud.sh resetenv <service> NAME      put that setting back to its default
#   cloud.sh bgsql "<statements>"         run SQL in a session that stays open
#   cloud.sh kafka-in <tool> [args...]    like kafka, with stdin passed through
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=$(cat .mode 2> /dev/null || echo compose)
CONTEXT=k3d-connectivity
NS=connectivity
EDGE=" edge-agent edge-agent-site-b site-gateway wan "

compose() {
  if [ "$MODE" = cluster ]; then
    COMPOSE_PROFILES='' WAN_UPSTREAM=host.docker.internal:8080 EDGE_OTLP_ENDPOINT=http://host.docker.internal:4318 docker compose "$@"
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

# AI triage's evals, run inside its container (it has the cases, the baked-in
# embedding model and the API key) against a scratch database next to the
# real one: evals write notes, spend and an index of their own, which must
# not mix with the live service's.
triage_eval() {
  local provider=$1 repeat=$2
  local dsn=postgresql://connectivity:connectivity@postgres:5432/triage_eval
  sql "SELECT 1 FROM pg_database WHERE datname = 'triage_eval'" | grep -q 1 || sql "CREATE DATABASE triage_eval"
  local args=(python -m triage eval --provider "$provider" --repeat "$repeat")
  if [ "$MODE" = cluster ]; then
    k exec deployment/ai-triage -- env DATABASE_URL="$dsn" "${args[@]}"
  else
    compose exec -T -e DATABASE_URL="$dsn" ai-triage "${args[@]}"
  fi
}

# The fake model's fault injection lives in each process, so in cluster mode
# it's set on every replica directly: through the Service it would reach
# whichever one the load balancer picked.
triage_faults() {
  local spec=$1
  if [ "$MODE" = cluster ]; then
    local pod
    for pod in $(k get pods -l app=ai-triage -o name); do
      printf '%s: ' "${pod#pod/}"
      k exec "$pod" -- python -c 'import sys, urllib.parse, urllib.request
q = urllib.parse.urlencode({"spec": sys.argv[1]})
print(urllib.request.urlopen(urllib.request.Request("http://localhost:8086/debug/llm-faults?" + q, method="POST")).read().decode())' "$spec"
    done
  else
    curl -fsS -X POST -G localhost:8086/debug/llm-faults --data-urlencode "spec=$spec"; echo
  fi
}

# The pager, from wherever it can be reached. Its host port exists in compose
# mode and on clusters created since it was added; on an older cluster, ask
# it from inside its own pod.
pager() {
  local method=$1 path=$2 body=${3:-}
  local args=(-fsS --max-time 5 -X "$method")
  [ -z "$body" ] || args+=(-H 'Content-Type: application/json' --data "$body")
  if curl "${args[@]}" "localhost:9099$path" 2> /dev/null; then return; fi
  [ "$MODE" = cluster ] || { echo "the pager is not reachable on localhost:9099" >&2; return 1; }
  k exec deployment/pager -- python -c 'import sys, urllib.request
method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request("http://localhost:9099" + path, data=body.encode() or None, method=method)
print(urllib.request.urlopen(req, timeout=5).read().decode())' "$method" "$path" "$body"
}

# Everything in a topic's dead-letter topic: where each record came from, why
# it was set aside (the x-dlq-* headers), its key and its value.
dlq() {
  local topic=${1:-telemetry.raw}
  kafka kafka-console-consumer --topic "${topic%.dlq}.dlq" --from-beginning --timeout-ms 8000 \
    --property print.offset=true --property print.headers=true --property print.key=true 2> /dev/null || true
}

kafka_in() {
  local tool=$1; shift
  if [ "$MODE" = cluster ]; then
    local b; b=$(broker)
    [ -n "$b" ] || { echo "no Kafka broker is ready" >&2; exit 1; }
    k exec -i "$b" -- "/opt/kafka/bin/$tool.sh" --bootstrap-server localhost:9092 "$@"
  else
    compose exec -T kafka "/opt/kafka/bin/$tool.sh" --bootstrap-server localhost:9092 "$@"
  fi
}

# One setting of one service, changed and later put back. In cluster mode a
# cloud service's Deployment gets the variable directly. In Compose the
# setting must be one docker-compose.yml reads from the environment; those
# are remembered in .drills/overrides.env so that changing a second setting
# doesn't undo the first. (A plain `make up` ignores that file, and so puts
# every service back to its defaults.)
compose_var() {
  case "$1/$2" in
    ingest-api/PRODUCE_TIMEOUT) echo INGEST_PRODUCE_TIMEOUT ;;
    ingest-api/MAX_IN_FLIGHT) echo INGEST_MAX_IN_FLIGHT ;;
    ingest-api/TOKEN_SECRET | ingest-api/ENROLLMENT_KEY) echo "$2" ;;
    telemetry-processor/CONSUMER_GROUP) echo PROCESSOR_CONSUMER_GROUP ;;
    telemetry-processor/TELEMETRY_RETENTION | telemetry-processor/BATCH_ID_RETENTION) echo "$2" ;;
    edge-agent/CLOCK_SKEW_MAX | edge-agent-site-b/CLOCK_SKEW_MAX) echo CLOCK_SKEW_MAX ;;
    edge-agent/FIRMWARE_MIX | edge-agent-site-b/FIRMWARE_MIX) echo FIRMWARE_MIX ;;
    *) echo "no compose variable for $2 on $1; add one to docker-compose.yml and scripts/cloud.sh" >&2; return 1 ;;
  esac
}

compose_apply_overrides() {
  local svc=$1 f=.drills/overrides.env
  mkdir -p .drills && touch "$f"
  (
    set -a
    # shellcheck disable=SC1090
    . "./$f"
    set +a
    compose up -d --no-deps "$svc"
  )
}

setenv() {
  local svc=$1 name=${2%%=*} value=${2#*=}
  if on_cluster "$svc"; then
    k set env "deployment/$svc" "$name=$value" > /dev/null
    k rollout status "deployment/$svc" --timeout=5m > /dev/null
    return
  fi
  local var f=.drills/overrides.env
  var=$(compose_var "$svc" "$name")
  mkdir -p .drills && touch "$f"
  grep -v "^$var=" "$f" > "$f.tmp" || true
  printf "%s='%s'\n" "$var" "$value" >> "$f.tmp"
  mv "$f.tmp" "$f"
  compose_apply_overrides "$svc" > /dev/null 2>&1
}

resetenv() {
  local svc=$1 name=$2
  if on_cluster "$svc"; then
    k set env "deployment/$svc" "$name-" > /dev/null
    k rollout status "deployment/$svc" --timeout=5m > /dev/null
    return
  fi
  local var f=.drills/overrides.env
  var=$(compose_var "$svc" "$name")
  mkdir -p .drills && touch "$f"
  grep -v "^$var=" "$f" > "$f.tmp" || true
  mv "$f.tmp" "$f"
  compose_apply_overrides "$svc" > /dev/null 2>&1
}

# SQL in a session that outlives this command: for a lock or a transaction
# that has to stay open.
bgsql() {
  if [ "$MODE" = cluster ]; then
    # shellcheck disable=SC2016
    k exec postgres-0 -- sh -c 'nohup psql -U connectivity -d connectivity -c "$1" > /dev/null 2>&1 &' sh "$1"
  else
    compose exec -d postgres "${psql_args[@]}" -c "$1"
  fi
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
  triage-eval) triage_eval "${1:-fake}" "${2:-1}" ;;
  triage-faults) triage_faults "${1:-}" ;;
  pager) pager "$@" ;;
  dlq) dlq "${1:-}" ;;
  setenv) setenv "$1" "$2" ;;
  resetenv) resetenv "$1" "$2" ;;
  bgsql) bgsql "$1" ;;
  kafka-in) kafka_in "$@" ;;
  mode) echo "$MODE" ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
