# Run from connectivity-platform. Component repos live next to this one;
# scripts/bootstrap.sh sets that up.
#
# Two ways to run the cloud side:
#   compose mode   make up           everything in Docker Compose; light and fast
#   cluster mode   make cluster-up   the cloud on a three-node k3d cluster, with
#                                    three Kafka brokers, Loki, Tempo and Chaos Mesh
# The edge (agents, site gateway) and the WAN proxy run in Compose either way.
# Targets that touch cloud services (psql, lag, stop s=kafka, ...) work in both
# modes: scripts/cloud.sh reads .mode and uses docker compose or kubectl.
WORKSPACE := ..
SERVICES  := connectivity-edge-agent connectivity-ingest-api connectivity-telemetry-processor connectivity-case-service
MODULES   := connectivity-contracts connectivity-go-kit $(SERVICES)
GATEWAY   := connectivity-site-gateway
MODE      := $(shell cat .mode 2>/dev/null || echo compose)
CLOUD     := ./scripts/cloud.sh
WAN       := ./scripts/wan.sh
KUBECTL   := kubectl --context k3d-connectivity -n connectivity

# Compose runs the cloud services only in compose mode; in cluster mode it
# runs the edge, and the WAN forwards to the cluster's ingress.
ifeq ($(MODE),cluster)
export COMPOSE_PROFILES :=
export WAN_UPSTREAM := host.docker.internal:8080
export EDGE_OTLP_ENDPOINT := http://host.docker.internal:4318
else
export COMPOSE_PROFILES := cloud
endif
COMPOSE := docker compose

.PHONY: bootstrap tidy test up down ps logs stop start restart kill psql bundles lag topics devices gateway \
        cases case resolve fault rules replay answers plant \
        triage triages retriage runbooks eval llm-faults \
        wan wan-latency wan-bandwidth wan-flaky wan-blackhole wan-down wan-up wan-clear wan-reset \
        cluster-up cluster-down deploy edge cluster-status chaos-install chaos chaos-ls chaos-stop

bootstrap: ## clone or update every component repo and create go.work
	./scripts/bootstrap.sh

tidy: ## refresh go.mod and go.sum in every module against released versions
	@for m in $(MODULES); do echo "tidy $$m"; (cd $(WORKSPACE)/$$m && GOWORK=off go mod tidy) || exit 1; done

test: ## unit tests: Go modules with the race detector, then the Java gateway if Maven is installed
	@for m in $(MODULES); do echo "test $$m"; (cd $(WORKSPACE)/$$m && go test -race ./...) || exit 1; done
	@if command -v mvn > /dev/null; then echo "test $(GATEWAY)"; (cd $(WORKSPACE)/$(GATEWAY) && mvn -B -ntp -q verify); \
	 else echo "skip $(GATEWAY): mvn not installed (docker still builds and tests it in CI)"; fi

# ---------- compose mode ----------
up: ## compose mode: build images and start the whole stack
	@[ "$(MODE)" = compose ] || { echo "cluster mode is running; make cluster-down first"; exit 1; }
	$(COMPOSE) up -d --build

down: ## compose mode: stop everything and delete data
	@[ "$(MODE)" = compose ] || { echo "cluster mode is running; use make cluster-down"; exit 1; }
	$(COMPOSE) down -v

# ---------- cluster mode ----------
cluster-up: ## cluster mode: create the k3d cluster, deploy the cloud, start the edge
	./scripts/cluster.sh up

cluster-down: ## delete the cluster and the edge, with all data
	./scripts/cluster.sh down

deploy: ## rebuild the cloud services from their repos and roll them out (also applies edited rules.json)
	./scripts/cluster.sh deploy

edge: ## restart the edge and the WAN against the cluster (e.g. after changing DEVICE_COUNT)
	./scripts/cluster.sh edge

cluster-status: ## nodes, pods, and the image each workload runs
	./scripts/cluster.sh status

chaos-install: ## install Chaos Mesh into the cluster (needs helm)
	./scripts/cluster.sh chaos-install

chaos: ## run an experiment from k8s/chaos: make chaos e=kafka-broker-kill
	@[ -f k8s/chaos/$(e).yaml ] || { echo "no experiment k8s/chaos/$(e).yaml; see make chaos-ls"; exit 1; }
	@$(KUBECTL) delete -f k8s/chaos/$(e).yaml --ignore-not-found > /dev/null
	$(KUBECTL) create -f k8s/chaos/$(e).yaml

chaos-ls: ## experiments you can run, then the ones in the cluster now
	@ls k8s/chaos | sed 's/\.yaml$$//'
	@echo "--- in the cluster"; $(KUBECTL) get podchaos,networkchaos,stresschaos,schedule 2>/dev/null || true

chaos-stop: ## end every experiment now
	$(KUBECTL) delete podchaos,networkchaos,stresschaos,schedule --all

# ---------- both modes ----------
ps:
	@$(CLOUD) ps

logs: ## make logs s=telemetry-processor   (in cluster mode also a pod: s=kafka-1)
	@$(CLOUD) logs $(s)

stop: ## make stop s=kafka   (graceful outage; cluster mode scales to zero)
	@$(CLOUD) stop $(s)

start: ## make start s=kafka
	@$(CLOUD) start $(s)

restart: ## make restart s=case-service   (cluster mode: a rolling restart)
	@$(CLOUD) restart $(s)

kill: ## make kill s=telemetry-processor   (no graceful shutdown; cluster mode also takes a pod: s=kafka-1)
	@$(CLOUD) kill $(s)

psql:
	@$(CLOUD) psql

bundles: ## latest log bundles indexed
	@$(CLOUD) query "SELECT device_id, reason, size_bytes, collected_at, indexed_at - collected_at AS delay FROM log_bundles ORDER BY collected_at DESC LIMIT 15"

lag: ## consumer group offsets and lag per partition: make lag [g=case-service]
	@$(CLOUD) kafka kafka-consumer-groups --describe --group $(or $(g),telemetry-processor)

topics: ## partitions, leaders and in-sync replicas for every topic
	@$(CLOUD) kafka kafka-topics --describe

devices: ## site B inventory as the gateway sees it: counts by status, then the stalest devices
	@curl -fsS localhost:8090/gateway/v1/devices | python3 -c 'import json,sys,collections; d=json.load(sys.stdin); v=d["devices"]; \
	  print(d["gateway_id"], dict(collections.Counter(x["status"] for x in v))); \
	  [print(" ", x["deviceId"], x["status"], "last seen", x["lastSeen"]) for x in sorted(v, key=lambda x: x["lastSeen"])[:10]]'

gateway: ## the gateway's store-and-forward queue and drop counters
	@curl -fsS localhost:8090/metrics | grep -E '^connectivity_gateway_(queue_records|queue_bytes|queued_total|forwarded_total|queue_dropped_total|forward_failures_total)'

# ---------- the WAN between each site and the cloud ----------
wan: ## each site's WAN link and the faults on it
	@$(WAN) show

wan-latency: ## make wan-latency site=b ms=2000 [jitter=500]
	@$(WAN) latency $(site) $(ms) $(or $(jitter),0)

wan-bandwidth: ## make wan-bandwidth site=b kbps=32   (KB/s, site to cloud)
	@$(WAN) bandwidth $(site) $(kbps)

wan-flaky: ## make wan-flaky site=a pct=30   (reset 30% of new connections)
	@$(WAN) flaky $(site) $(pct)

wan-blackhole: ## make wan-blackhole site=b   (connections hang; clients time out)
	@$(WAN) blackhole $(site)

wan-down: ## make wan-down site=b   (connections refused)
	@$(WAN) down $(site)

wan-up: ## make wan-up site=b
	@$(WAN) up $(site)

wan-clear: ## make wan-clear site=b   (remove that link's faults)
	@$(WAN) clear $(site)

wan-reset: ## every link up, no faults
	@$(WAN) reset

# ---------- alerts and cases ----------
CASES_URL := http://localhost:8085

cases: ## cases, newest first: make cases [status=open|resolved|all] [site=a|b]
	@python3 scripts/cases.py $(CASES_URL) '$(status)' '$(site)'

case: ## one case with its alerts, bundles and children: make case id=12
	@curl -fsS $(CASES_URL)/v1/cases/$(id) | python3 -m json.tool

resolve: ## make resolve id=12 why="replaced fan"
	@curl -fsS -X POST $(CASES_URL)/v1/cases/$(id)/resolve -d '{"resolution": "$(or $(why),resolved)"}'; echo

rules: ## the case rules in effect
	@curl -fsS $(CASES_URL)/v1/rules | python3 -m json.tool

fault: ## force a fault: make fault kind=thermal|psu|disk [cause=fan_failure|...] [site=a|b] [n=3|all] [device=site-a-00007]
	@port=$$( [ "$(site)" = b ] && echo 9103 || echo 9102 ); \
	 curl -fsS -X POST "localhost:$$port/debug/faults?kind=$(kind)&cause=$(cause)&devices=$(or $(n),1)&device=$(device)"; echo

answers: ## the true causes behind recent alerts, from the edge agent's answer key: make answers [site=a|b] [device=...]
	@port=$$( [ "$(site)" = b ] && echo 9103 || echo 9102 ); \
	 curl -fsS "localhost:$$port/debug/faults?device=$(device)&limit=$(or $(n),20)" | python3 -m json.tool

plant: ## plant a line in device logs for their next bundle: make plant [site=a|b] [device=...|n=3|all] [line="..."] [repeat=N] (default line: a prompt injection)
	@port=$$( [ "$(site)" = b ] && echo 9103 || echo 9102 ); q="devices=$(or $(n),1)&device=$(device)&repeat=$(or $(repeat),1)"; \
	 if [ -n '$(line)' ]; then curl -fsS -X POST --data-binary '$(line)' "localhost:$$port/debug/logs?$$q"; \
	 else curl -fsS -X POST "localhost:$$port/debug/logs?preset=prompt_injection&$$q"; fi; echo

replay: ## replay every alert through the case service from offset 0; no case should change
	@$(CLOUD) replay

# ---------- AI triage ----------
TRIAGE_URL := http://localhost:8086

triages: ## recent triage notes, newest first
	@python3 scripts/triages.py $(TRIAGE_URL)

triage: ## one case's triage note, with its evidence checks, cost and latency: make triage id=12
	@curl -fsS $(TRIAGE_URL)/v1/triage/$(id) | python3 -m json.tool

retriage: ## triage a case again now, even if nothing changed: make retriage id=12
	@curl -fsS -X POST $(TRIAGE_URL)/v1/triage/$(id)/rerun; echo

runbooks: ## search the runbooks the way triage does: make runbooks q="PSU1 AC input lost" [code=power.rail_out_of_range]
	@curl -fsS -G $(TRIAGE_URL)/v1/runbooks/search --data-urlencode "q=$(q)" --data-urlencode "code=$(code)" | python3 -m json.tool

eval: ## run triage's evals against a scratch database: make eval [provider=fake|anthropic|ollama] [repeat=3]
	@$(CLOUD) triage-eval '$(or $(provider),fake)' '$(or $(repeat),1)'

llm-faults: ## make the fake model misbehave, on every replica: make llm-faults spec="rate_limit=0.5,latency_ms=2000" (no spec clears)
	@$(CLOUD) triage-faults '$(spec)'
