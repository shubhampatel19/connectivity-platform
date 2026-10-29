# Run from connectivity-platform. Component repos live next to this one;
# scripts/bootstrap.sh sets that up.
WORKSPACE := ..
SERVICES  := connectivity-edge-agent connectivity-ingest-api connectivity-telemetry-processor connectivity-case-service
MODULES   := connectivity-contracts connectivity-go-kit $(SERVICES)
GATEWAY   := connectivity-site-gateway
COMPOSE   := docker compose

.PHONY: bootstrap tidy test up down ps logs stop start restart kill psql bundles lag topics devices gateway cases case resolve fault rules replay

bootstrap: ## clone or update every component repo and create go.work
	./scripts/bootstrap.sh

tidy: ## refresh go.mod and go.sum in every module against released versions
	@for m in $(MODULES); do echo "tidy $$m"; (cd $(WORKSPACE)/$$m && GOWORK=off go mod tidy) || exit 1; done

test: ## unit tests: Go modules with the race detector, then the Java gateway if Maven is installed
	@for m in $(MODULES); do echo "test $$m"; (cd $(WORKSPACE)/$$m && go test -race ./...) || exit 1; done
	@if command -v mvn > /dev/null; then echo "test $(GATEWAY)"; (cd $(WORKSPACE)/$(GATEWAY) && mvn -B -ntp -q verify); \
	 else echo "skip $(GATEWAY): mvn not installed (docker still builds and tests it in CI)"; fi

up: ## build images and start the whole stack
	$(COMPOSE) up -d --build

down: ## stop everything and delete data
	$(COMPOSE) down -v

ps:
	$(COMPOSE) ps

logs: ## make logs s=telemetry-processor
	$(COMPOSE) logs -f --tail=100 $(s)

stop: ## make stop s=kafka   (graceful outage)
	$(COMPOSE) stop $(s)

start: ## make start s=kafka
	$(COMPOSE) start $(s)

restart: ## make restart s=case-service   (e.g. after editing case-service/rules.json)
	$(COMPOSE) restart $(s)

kill: ## make kill s=telemetry-processor   (SIGKILL, no graceful shutdown)
	$(COMPOSE) kill -s SIGKILL $(s)

psql:
	$(COMPOSE) exec postgres psql -U connectivity -d connectivity

bundles: ## latest log bundles indexed
	$(COMPOSE) exec postgres psql -U connectivity -d connectivity -c "SELECT device_id, reason, size_bytes, collected_at, indexed_at - collected_at AS delay FROM log_bundles ORDER BY collected_at DESC LIMIT 15"

lag: ## consumer group offsets and lag per partition: make lag [g=case-service]
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group $(or $(g),telemetry-processor)

topics:
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe

devices: ## site B inventory as the gateway sees it: counts by status, then the stalest devices
	@curl -fsS localhost:8090/gateway/v1/devices | python3 -c 'import json,sys,collections; d=json.load(sys.stdin); v=d["devices"]; \
	  print(d["gateway_id"], dict(collections.Counter(x["status"] for x in v))); \
	  [print(" ", x["deviceId"], x["status"], "last seen", x["lastSeen"]) for x in sorted(v, key=lambda x: x["lastSeen"])[:10]]'

gateway: ## the gateway's store-and-forward queue and drop counters
	@curl -fsS localhost:8090/metrics | grep -E '^connectivity_gateway_(queue_records|queue_bytes|queued_total|forwarded_total|queue_dropped_total|forward_failures_total)'

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

fault: ## force a fault: make fault kind=thermal|psu|disk [site=a|b] [n=3|all] [device=site-a-00007]
	@port=$$( [ "$(site)" = b ] && echo 9103 || echo 9102 ); \
	 curl -fsS -X POST "localhost:$$port/debug/faults?kind=$(kind)&devices=$(or $(n),1)&device=$(device)"; echo

replay: ## replay every alert through the case service from offset 0; no case should change
	$(COMPOSE) stop case-service
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --group case-service --reset-offsets --to-earliest --all-topics --execute
	$(COMPOSE) start case-service
