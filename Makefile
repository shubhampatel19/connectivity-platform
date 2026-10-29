# Run from connectivity-platform. Component repos live next to this one;
# scripts/bootstrap.sh sets that up.
WORKSPACE := ..
SERVICES  := connectivity-edge-agent connectivity-ingest-api connectivity-telemetry-processor
MODULES   := connectivity-contracts connectivity-go-kit $(SERVICES)
COMPOSE   := docker compose

.PHONY: bootstrap tidy test up down ps logs stop start kill psql bundles lag topics

bootstrap: ## clone or update every component repo and create go.work
	./scripts/bootstrap.sh

tidy: ## refresh go.mod and go.sum in every module against released versions
	@for m in $(MODULES); do echo "tidy $$m"; (cd $(WORKSPACE)/$$m && GOWORK=off go mod tidy) || exit 1; done

test: ## unit tests with the race detector, across the workspace
	@for m in $(MODULES); do echo "test $$m"; (cd $(WORKSPACE)/$$m && go test -race ./...) || exit 1; done

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

kill: ## make kill s=telemetry-processor   (SIGKILL, no graceful shutdown)
	$(COMPOSE) kill -s SIGKILL $(s)

psql:
	$(COMPOSE) exec postgres psql -U connectivity -d connectivity

bundles: ## latest log bundles indexed
	$(COMPOSE) exec postgres psql -U connectivity -d connectivity -c "SELECT device_id, reason, size_bytes, collected_at, indexed_at - collected_at AS delay FROM log_bundles ORDER BY collected_at DESC LIMIT 15"

lag: ## consumer group offsets and lag per partition
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group telemetry-processor

topics:
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe
