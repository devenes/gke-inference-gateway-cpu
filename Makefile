PROJECT_ID   ?= your-gcp-project-id
REGION       ?= us-central1
ZONE         ?= us-central1-a
CLUSTER_NAME ?= gke-inference-gw-cpu
TF_DIR       := terraform

.PHONY: help preflight init fmt validate plan infra credentials deploy status test test-classifier test-auto-routing test-streaming metrics benchmark diagnostics logs destroy

help: ## Show available Makefile targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

preflight: ## Verify local CLI tools, gcloud auth, ADC, project access, and billing
	@PROJECT_ID=$(PROJECT_ID) REGION=$(REGION) ZONE=$(ZONE) ./scripts/preflight.sh

init: ## Initialize Terraform providers and backend
	terraform -chdir=$(TF_DIR) init

fmt: ## Check Terraform formatting
	terraform -chdir=$(TF_DIR) fmt -check

validate: init ## Validate Terraform configuration
	terraform -chdir=$(TF_DIR) validate

plan: init ## Run Terraform plan
	terraform -chdir=$(TF_DIR) plan \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="zone=$(ZONE)" \
		-var="cluster_name=$(CLUSTER_NAME)"

infra: init ## Provision GCP & GKE infrastructure via Terraform
	terraform -chdir=$(TF_DIR) apply -auto-approve \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="zone=$(ZONE)" \
		-var="cluster_name=$(CLUSTER_NAME)"

credentials: ## Configure kubectl credentials for the GKE cluster
	gcloud container clusters get-credentials $(CLUSTER_NAME) --zone $(ZONE) --project $(PROJECT_ID)

deploy: ## Deploy CRDs, CPU models, InferencePools, EPPs, BBR, auto-model-router, Gateway, and HTTPRoute
	@PROJECT_ID=$(PROJECT_ID) ZONE=$(ZONE) CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/deploy.sh

status: ## Display cluster nodes, pods, InferencePools, Gateway, and public endpoint IP
	@./scripts/status.sh

test: ## Run end-to-end curl tests against the public GKE Inference Gateway endpoint
	@./scripts/test-e2e.sh

test-classifier: ## Run unit and request contract tests for the rule-based complexity classifier
	@python3 -m unittest discover -s router -p "test_*.py" -v

test-auto-routing: ## Run end-to-end explicit and automatic model routing tests through the public Gateway
	@./scripts/test-auto-routing.sh

test-streaming: ## Verify Server-Sent Events (SSE) streaming and measure true TTFT for explicit and automatic modes
	@./scripts/test-streaming.sh

metrics: ## Collect and summarize Prometheus metrics from both model servers and Endpoint Pickers
	@./scripts/collect-metrics.sh

benchmark: ## Run sequential and bounded concurrent end-to-end latency/throughput benchmarks
	@CLUSTER_NAME=$(CLUSTER_NAME) ZONE=$(ZONE) ./scripts/benchmark.sh

diagnostics: ## Run status, metrics collection, and SSE streaming verification in sequence
	@./scripts/status.sh
	@./scripts/collect-metrics.sh
	@./scripts/test-streaming.sh

logs: ## Tail logs from Body-Based Router, auto-model-router, EPPs, and model servers
	kubectl logs deployment/body-based-router --tail=30
	kubectl logs deployment/auto-model-router --tail=30
	kubectl logs deployment/qwen-pool-epp --tail=30
	kubectl logs deployment/smollm-pool-epp --tail=30
	kubectl logs deployment/qwen-demo -c llama-server --tail=30
	kubectl logs deployment/smollm-demo -c llama-server --tail=30

destroy: ## Tear down Kubernetes Gateway resources and destroy Terraform infrastructure (manual only)
	-kubectl delete -f k8s/gateway/ --ignore-not-found=true
	-kubectl delete -f k8s/inference/auto-model-router.yaml --ignore-not-found=true
	-helm uninstall body-based-router --ignore-not-found
	-helm uninstall qwen-pool --ignore-not-found
	-helm uninstall smollm-pool --ignore-not-found
	-kubectl delete -f k8s/inference/inference-objectives.yaml --ignore-not-found=true
	-kubectl delete -f k8s/models/ --ignore-not-found=true
	@echo "Waiting 90s for GKE Gateway controller to release regional load balancer resources..."
	sleep 90
	terraform -chdir=$(TF_DIR) destroy -auto-approve \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="zone=$(ZONE)" \
		-var="cluster_name=$(CLUSTER_NAME)"
