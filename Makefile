# EKS Auto Mode + vLLM LLM serving - lifecycle.
#
# Typical flow:
#   make preflight        # checks creds, tooling, GPU quota
#   make up               # provision infra (VPC, EKS Auto Mode, S3, ECR, tunnel)
#   make stage            # download model weights -> S3 (out-of-band, your laptop)
#   make prewarm          # warm the ECR pull-through cache with the vLLM image
#   make image            # build + push the Streamlit image to ECR
#   make tunnel           # (terminal 1) open SSM tunnel to the private API
#   export KUBECONFIG=$(PWD)/kubeconfig
#   make deploy           # (terminal 2) apply GPU NodePool + vLLM + Streamlit
#   make verify           # port-forward Streamlit to http://localhost:8501
#   make down             # tear everything down

REGION ?= ca-central-1
export REGION

# Auto-detect OpenTofu, fall back to Terraform.
TF := $(shell command -v tofu >/dev/null 2>&1 && echo "tofu" || echo "terraform")
TF_DIR := terraform

.PHONY: help preflight init up stage prewarm image tunnel deploy verify scale-down scale-up down fmt validate output diagrams

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

preflight: ## Check creds, tooling, and GPU quota
	@bash scripts/preflight.sh

init: ## tofu/terraform init
	$(TF) -chdir=$(TF_DIR) init

up: ## Provision infrastructure (idempotent)
	$(TF) -chdir=$(TF_DIR) init -upgrade
	$(TF) -chdir=$(TF_DIR) apply -var="region=$(REGION)"

stage: ## Download model weights to S3 (out-of-band)
	@bash scripts/stage-model.sh

prewarm: ## Warm the ECR pull-through cache with the vLLM image
	@bash scripts/prewarm-image.sh

image: ## Build + push the Streamlit image to ECR
	@bash scripts/build-streamlit.sh

tunnel: ## Open SSM tunnel to the private API (run in its own terminal)
	@bash scripts/tunnel.sh

deploy: ## Apply workloads (needs tunnel up + KUBECONFIG set)
	@bash scripts/deploy.sh

verify: ## Port-forward Streamlit to http://localhost:8501
	@bash scripts/verify.sh

scale-down: ## Stop the model (scale to 0); GPU node terminates, cluster stays (needs tunnel)
	kubectl -n llm scale deployment/vllm deployment/streamlit --replicas=0
	@echo "Scaled to 0. The GPU node terminates a few minutes after the vLLM pod is gone (consolidation + drain)."
	@echo "Cluster, S3 weights, and ECR cache remain. Run 'make scale-up' to restart."

scale-up: ## Restart the model (scale back to 1); provisions a fresh GPU node (needs tunnel)
	kubectl -n llm scale deployment/vllm deployment/streamlit --replicas=1
	@echo "Scaling up. Karpenter provisions a GPU node (~2 min) then vLLM streams weights."
	@echo "Watch: kubectl -n llm get pods -w"

down: ## Tear everything down (cluster cleanup, then destroy)
	@bash scripts/destroy.sh -var="region=$(REGION)"

fmt: ## Format terraform
	$(TF) -chdir=$(TF_DIR) fmt -recursive

validate: ## Validate terraform
	$(TF) -chdir=$(TF_DIR) validate

output: ## Show infra outputs
	$(TF) -chdir=$(TF_DIR) output

diagrams: ## Export diagrams/*.drawio → docs/diagrams/*.svg
	@bash scripts/export-diagrams.sh

