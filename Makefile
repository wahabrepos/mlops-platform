# The Makefile is the interface to this repository.
#
# Everything you do more than once lives here, so that the README can say
# `make local-up` instead of a nine-line docker compose invocation, and so that
# the command you run is the same one CI runs. When a command in the README
# drifts from the command that works, this file is where the truth lives.
#
# `make` with no target prints the help below. That is deliberate: a Makefile
# you have to read to use is a Makefile nobody uses.

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE := docker compose -f platform/local/docker-compose.yml --env-file platform/local/.env
PROFILE ?= core
GIT_SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
REGISTRY ?= localhost:5001

# .PHONY tells make these targets are commands, not files to build. Without it,
# a target named `test` silently stops working the day someone creates a
# directory called `test`.
.PHONY: help local-up local-down local-logs local-reset seed seed-bad \
        run test test-race lint fmt build docker-build \
        kind-up kind-down k8s-deploy \
        tf-init tf-plan tf-apply tf-backup azure-up azure-down azure-cost azure-status \
        policy-test ci clean \
        vm-up vm-ssh vm-down vm-status

## ---------------------------------------------------------------- help ----

help: ## Show this help
	@echo ""
	@echo "  mlops-platform — targets"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  PROFILE=core|airflow|obs|lineage  selects which local services start"
	@echo ""

## ------------------------------------------------------- local platform ----

local-up: platform/local/.env ## Start the local stack (PROFILE=core|airflow|obs|lineage)
	$(COMPOSE) --profile $(PROFILE) up -d --build
	@echo ""
	@echo "  MinIO console  http://localhost:9001   (minioadmin / minioadmin)"
	@echo "  MLflow         http://localhost:5000"
	@echo "  Airflow        http://localhost:8081   (PROFILE=airflow)"
	@echo "  Grafana        http://localhost:3001   (PROFILE=obs, admin/admin)"
	@echo "  Prometheus     http://localhost:9090   (PROFILE=obs)"
	@echo ""

local-down: ## Stop the local stack, keep the data volumes
	$(COMPOSE) --profile core --profile airflow --profile obs --profile lineage down

local-logs: ## Tail logs from the local stack
	$(COMPOSE) logs -f --tail=100

local-reset: ## Stop everything AND delete all local data. Destructive.
	$(COMPOSE) --profile core --profile airflow --profile obs --profile lineage down -v
	rm -rf platform/local/volumes
	@echo "local state wiped; next `make local-up` starts from empty"

# Auto-create .env from the example the first time it is needed. A missing
# .env produces a confusing docker compose error; this turns it into a no-op.
platform/local/.env:
	cp platform/local/.env.example platform/local/.env
	@echo "created platform/local/.env from the example — review it"

seed: ## Upload one clean day of synthetic ALPR data
	python3 scripts/seed_demo_data.py --date $${DATE:-2026-09-01}

seed-bad: ## Upload one deliberately broken day, to prove the quality gate blocks it
	python3 scripts/seed_demo_data.py --date $${DATE:-2026-09-02} --corrupt

## -------------------------------------------------------------- service ----

run: ## Run dataset-api locally on :8080 with a persistent catalog
	SNAPSHOT_PATH=platform/local/volumes/catalog.json \
	go run ./services/dataset-api/cmd/api

test: ## Run all Go tests
	go test ./...

test-race: ## Run all Go tests with the race detector (what CI runs)
	go test -race -count=1 ./...

lint: ## gofmt check + go vet
	@unformatted=$$(gofmt -l .); \
	if [ -n "$$unformatted" ]; then echo "not gofmt'd:"; echo "$$unformatted"; exit 1; fi
	go vet ./...
	@echo "lint clean"

fmt: ## Format Go and Terraform in place
	gofmt -w .
	command -v terraform >/dev/null && terraform fmt -recursive platform/terraform || true

# `go build -o bin/ ./...` names each binary after its PACKAGE DIRECTORY, so
# ./services/dataset-api/cmd/api becomes bin/api — meaningless once there are
# three services. Naming each output explicitly is the fix. Add a line here
# when you add a service.
build: ## Build every binary into ./bin
	mkdir -p bin
	go build -ldflags="-s -w -X main.version=$(GIT_SHA)" -o bin/dataset-api ./services/dataset-api/cmd/api
	@ls -lh bin/

docker-build: ## Build the dataset-api image
	docker build -f services/dataset-api/Dockerfile \
	  --build-arg VERSION=$(GIT_SHA) \
	  -t $(REGISTRY)/dataset-api:$(GIT_SHA) \
	  -t $(REGISTRY)/dataset-api:dev .
	@echo "built $(REGISTRY)/dataset-api:$(GIT_SHA)"

policy-test: ## Run the OPA policy tests
	opa test policy/opa -v

ci: lint test-race policy-test ## Everything CI runs, locally
	python3 pipelines/quality/expectations.py
	@echo "local CI passed"

## ----------------------------------------------------------- kubernetes ----

kind-up: ## Create the local kind cluster + a local image registry
	bash scripts/kind-up.sh

kind-down: ## Delete the kind cluster
	kind delete cluster --name mlops
	docker rm -f kind-registry 2>/dev/null || true

k8s-deploy: docker-build ## Push the image to the kind registry and apply the manifests
	docker push $(REGISTRY)/dataset-api:dev
	kubectl apply -k platform/k8s/dataset-api 2>/dev/null || kubectl apply -f platform/k8s/dataset-api
	kubectl rollout status deployment/dataset-api --timeout=120s

## ---------------------------------------------------------------- azure ----
#
# Two environments, on purpose:
#   shared  cheap, always on   (~$5/month: registry + data lake)
#   burst   expensive, ephemeral (~$0.22/hour: AKS)
#
# `make azure-up` and `make azure-down` only ever touch burst. The destroy you
# will run most often cannot delete anything you want to keep.

tf-init: ## terraform init for both environments
	terraform -chdir=platform/terraform/envs/shared init
	terraform -chdir=platform/terraform/envs/burst init

tf-plan: ## Plan the shared (always-on) environment
	terraform -chdir=platform/terraform/envs/shared plan

tf-apply: ## Apply the shared environment. ~$5/month. Do this once.
	terraform -chdir=platform/terraform/envs/shared apply

tf-backup: ## Copy local state somewhere safe. State loss means orphaned billable resources.
	@mkdir -p ~/.mlops-platform-state-backup
	@for e in shared burst; do \
	  f=platform/terraform/envs/$$e/terraform.tfstate; \
	  [ -f $$f ] && cp $$f ~/.mlops-platform-state-backup/$$e-$$(date +%Y%m%d-%H%M%S).tfstate && echo "backed up $$e"; \
	done

azure-up: ## Create the AKS burst cluster. STARTS BILLING (~$0.22/hour).
	@echo "This creates a billable AKS cluster. Ctrl-C within 5s to abort."
	@sleep 5
	terraform -chdir=platform/terraform/envs/burst apply
	@echo ""
	@echo "  Cluster up. Remember: make azure-down when you are finished."
	@echo ""

azure-down: ## Destroy the burst cluster. STOPS BILLING. Run this every time.
	terraform -chdir=platform/terraform/envs/burst destroy
	@echo "burst environment destroyed; only the ~$$5/month shared resources remain"

azure-status: ## Is anything expensive running right now?
	@echo "== resource groups =="
	@az group list --query "[?tags.project=='mlops-platform'].{name:name,env:tags.environment,created:tags.created}" -o table 2>/dev/null || echo "  (az not logged in)"
	@echo ""
	@echo "== AKS clusters (these are the billable ones) =="
	@az aks list --query "[].{name:name,rg:resourceGroup,nodes:agentPoolProfiles[0].count,size:agentPoolProfiles[0].vmSize}" -o table 2>/dev/null || true

azure-cost: ## Month-to-date spend by service
	@az consumption usage list --start-date $$(date -d "$$(date +%Y-%m-01)" +%Y-%m-%d) --end-date $$(date +%Y-%m-%d) \
	  --query "[].{service:meterCategory,cost:pretaxCost}" -o tsv 2>/dev/null \
	  | awk -F'\t' '{s[$$1]+=$$2} END {for (k in s) printf "%-34s %8.2f\n", k, s[k]}' | sort -k2 -rn \
	  || echo "  consumption API is not available on all subscription types; use the portal's Cost Analysis blade"

## ----------------------------------------------------------- azure devbox ----
#
# The heavy local stack (Postgres + MinIO + MLflow + Airflow) runs on an Azure
# VM rather than on this workstation, which has ~2.6 GiB free. These targets are
# the whole lifecycle of that box.
#
# Deallocate, never stop. `az vm stop` powers the guest off but keeps the
# hardware reserved and you keep paying full compute for it. Only `deallocate`
# stops the meter. That distinction is encoded in vm-down so it does not have to
# be remembered.

VM_RG   ?= mlops-vm-rg
VM_NAME ?= mlops-vm
VM_USER ?= azureuser
VM_KEY  ?= $(HOME)/.ssh/id_ed25519

# Looked up rather than hard-coded, so recreating the VM does not strand these
# targets on a stale address. Recursive (=), so the lookup runs only when used.
VM_IP    = $(shell az network public-ip list -g $(VM_RG) --query "[0].ipAddress" -o tsv 2>/dev/null)

vm-up: ## Start the Azure dev VM. RESUMES BILLING (~$0.23/hour).
	@az vm start -g $(VM_RG) -n $(VM_NAME) -o none
	@ip="$(VM_IP)"; echo "  waiting for ssh on $$ip"; \
	 for i in $$(seq 1 30); do \
	   ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
	       -i $(VM_KEY) $(VM_USER)@$$ip true 2>/dev/null && break; \
	   sleep 5; \
	 done; \
	 echo ""; \
	 echo "  VM up at $$ip. Billing has resumed."; \
	 echo ""; \
	 echo "  The stack does NOT come back by itself - only dataset-api has a"; \
	 echo "  restart policy. To bring the rest up, on the VM:"; \
	 echo ""; \
	 echo "      make vm-ssh"; \
	 echo "      cd ~/mlops-platform && make local-up PROFILE=airflow"; \
	 echo ""

vm-ssh: ## Open a shell on the Azure dev VM
	@test -n "$(VM_IP)" || { echo "no public ip in $(VM_RG) - is the VM created?"; exit 1; }
	ssh -o StrictHostKeyChecking=accept-new -i $(VM_KEY) $(VM_USER)@$(VM_IP)

vm-down: ## Deallocate the dev VM. STOPS COMPUTE BILLING. Run this every time.
	@echo "  deallocating (not stopping - stop would keep billing)"
	@az vm deallocate -g $(VM_RG) -n $(VM_NAME) -o none
	@$(MAKE) --no-print-directory vm-status

vm-status: ## Is the dev VM running, and what is it costing?
	@state=$$(az vm get-instance-view -g $(VM_RG) -n $(VM_NAME) \
	    --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" \
	    -o tsv 2>/dev/null); \
	 if [ -z "$$state" ]; then \
	   echo "  no VM '$(VM_NAME)' in '$(VM_RG)' - nothing is billing"; \
	   exit 0; \
	 fi; \
	 echo "  state:  $$state"; \
	 echo "  ip:     $(VM_IP)"; \
	 case "$$state" in \
	   "VM running")     echo "  cost:   ~\$$0.23/hour NOW. make vm-down when you finish.";; \
	   "VM deallocated") echo "  cost:   compute stopped; ~\$$5/month for the disk and ip.";; \
	   "VM stopped")     echo "  WARNING: stopped is not deallocated - you are STILL paying"; \
	                     echo "           full compute. Run: make vm-down";; \
	   *)                echo "  cost:   unknown for this state";; \
	 esac

## ---------------------------------------------------------------- misc ----

clean: ## Remove build artifacts
	rm -rf bin coverage.out
	go clean -testcache
