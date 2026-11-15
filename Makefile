# EKS Auto Mode + vLLM LLM serving - lifecycle.
#
# Typical flow:
#   make preflight        # checks creds, tooling, GPU quota
#   make up               # provision infra (VPC, EKS Auto Mode, S3, ECR, tunnel)
#   make stage            # download model weights -> S3 (out-of-band, your laptop)
#   make weights          # download model weights -> ~/models (no AWS; for the spikes)
#   make prewarm          # warm the ECR pull-through cache with the vLLM image
#   make image            # build + push the Streamlit image to ECR
#   make tunnel           # (terminal 1) open SSM tunnel to the private API
#   export KUBECONFIG=$(PWD)/kubeconfig
#   make deploy           # (terminal 2) apply GPU NodePool + vLLM + Streamlit
#   make verify           # port-forward Streamlit to http://localhost:8501
#   make down             # tear everything down
#
# Add SPIKE=1 to any target to work on the Phase 0 spike stack instead: its own
# workspace (state), terraform/spike.tfvars, kubeconfig-spike and tunnel :8444.

REGION ?= ca-central-1
export REGION

# Auto-detect OpenTofu, fall back to Terraform.
TF := $(shell command -v tofu >/dev/null 2>&1 && echo "tofu" || echo "terraform")
TF_DIR := terraform

ifdef SPIKE
export TF_WORKSPACE := spike
TF_VARS := -var-file=spike.tfvars
export KUBECONFIG_FILE := $(CURDIR)/kubeconfig-spike
export LOCAL_PORT := 8444
endif

.PHONY: help preflight init up stage weights prewarm image tunnel deploy verify scale-down scale-up gpu-nodes down fmt validate test output diagrams

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

preflight: ## Check creds, tooling, and GPU quota
	@bash scripts/preflight.sh

init: ## tofu/terraform init
	$(TF) -chdir=$(TF_DIR) init

up: ## Provision infrastructure (idempotent)
	$(TF) -chdir=$(TF_DIR) init -upgrade
	$(TF) -chdir=$(TF_DIR) apply -var="region=$(REGION)" $(TF_VARS)

stage: ## Download model weights to S3 (out-of-band)
	@bash scripts/stage-model.sh

weights: ## Download model weights to ~/models for image packaging (no AWS needed)
	@bash scripts/download-weights.sh

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

gpu-nodes: ## Set the GPU node group's size: make gpu-nodes N=1 (or N=0)
	@test -n "$(N)" || { echo "usage: make gpu-nodes N=0|1"; exit 1; }
	aws eks update-nodegroup-config --region $(REGION) \
	  --cluster-name "$$($(TF) -chdir=$(TF_DIR) output -raw cluster_name)" \
	  --nodegroup-name "$$($(TF) -chdir=$(TF_DIR) output -raw gpu_node_group)" \
	  --scaling-config minSize=0,maxSize=1,desiredSize=$(N) --query 'update.status' --output text

down: ## Tear everything down (cluster cleanup, then destroy)
	@bash scripts/destroy.sh -var="region=$(REGION)" $(TF_VARS)

fmt: ## Format terraform
	$(TF) -chdir=$(TF_DIR) fmt -recursive

validate: ## Validate terraform
	$(TF) -chdir=$(TF_DIR) validate

test: ## Offline plan tests for the real and spike stacks (mocked AWS, no credentials)
	$(TF) -chdir=$(TF_DIR) init -backend=false -input=false >/dev/null
	$(TF) -chdir=$(TF_DIR) test

output: ## Show infra outputs
	$(TF) -chdir=$(TF_DIR) output

diagrams: ## Export diagrams/*.drawio → docs/diagrams/*.svg
	@bash scripts/export-diagrams.sh

