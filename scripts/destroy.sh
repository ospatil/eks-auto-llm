#!/usr/bin/env bash
# Reliable teardown. Order matters: delete in-cluster objects that provision AWS
# resources (LoadBalancer/Ingress) BEFORE destroying the VPC, or orphaned
# ELBs/ENIs/SGs will block VPC deletion.
#
# This stack uses only ClusterIP services (no LBs), so cluster-side cleanup is
# light - but we still best-effort delete the namespace + GPU NodePool so Auto
# Mode releases the GPU node before infra teardown. If the tunnel/kubeconfig
# isn't available, we skip straight to infra destroy (Auto Mode self-cleans its
# own EC2/ENI/SG via its service-linked role on cluster deletion).
set -euo pipefail

cd "$(dirname "$0")/.."
TF_DIR="terraform"
tf() { if command -v tofu >/dev/null 2>&1; then tofu -chdir="$TF_DIR" "$@"; else terraform -chdir="$TF_DIR" "$@"; fi; }

echo "== Step 1: best-effort cluster cleanup =="
if kubectl get ns llm >/dev/null 2>&1; then
  echo "  Deleting any LoadBalancer/Ingress objects (releases ELBs)…"
  kubectl delete ingress,svc --all-namespaces \
    --field-selector 'spec.type=LoadBalancer' --ignore-not-found 2>/dev/null || true
  echo "  Deleting llm namespace…"
  kubectl delete ns llm --ignore-not-found --timeout=120s 2>/dev/null || true
  echo "  Deleting GPU NodePool (lets Auto Mode drop the GPU node)…"
  kubectl delete -f k8s/gpu-nodepool.yaml --ignore-not-found 2>/dev/null || true
  echo "  Waiting 30s for the GPU node to drain…"
  sleep 30
else
  echo "  (cluster unreachable or already gone - skipping; Auto Mode self-cleans)"
fi

echo "== Step 2: delete the auto-created pull-through cache repo =="
# The pull-through cache rule auto-creates a backing repo (ecr-public/...) that
# Terraform doesn't manage, so `destroy` won't remove it. Delete it explicitly.
PT_REPO="ecr-public/$(tf output -raw vllm_image_uri 2>/dev/null | sed -E 's#.*/ecr-public/##; s#:.*##')"
if [ "$PT_REPO" != "ecr-public/" ]; then
  echo "  Deleting ECR repo ${PT_REPO} (if present)…"
  aws ecr delete-repository --repository-name "$PT_REPO" --force \
    --region "${REGION:-ca-central-1}" 2>/dev/null \
    && echo "  deleted" || echo "  (not present / already gone)"
fi

echo "== Step 3: tofu destroy =="
tf destroy "$@"

echo
echo "Teardown complete. Sanity-check for stragglers:"
echo "  aws ec2 describe-instances --filters Name=tag:Project,Values=eks-auto-llm --query 'Reservations[].Instances[].State.Name'"
