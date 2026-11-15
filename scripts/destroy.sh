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

echo "== Step 2: delete the ECR repos Terraform doesn't manage =="
# Pull-through cache rules auto-create their backing repos (<project>-pub/...,
# <project>-k8s/...), and mirror-image.sh / package-model.sh create repos under
# <project>/. Terraform doesn't manage any of those, so `destroy` won't remove
# them. Every name starts with the project, which keeps other repos safe.
PROJECT="$(tf output -raw project 2>/dev/null || true)"
STREAMLIT_REPO="$(tf output -raw ecr_streamlit_repo_url 2>/dev/null | sed -E 's#^[^/]+/##' || true)"
if [ -n "$PROJECT" ]; then
  repos="$(aws ecr describe-repositories --region "${REGION:-ca-central-1}" \
    --query 'repositories[].repositoryName' --output text 2>/dev/null | tr '\t' '\n' \
    | grep -E "^${PROJECT}(-pub|-k8s)?/" | grep -vxF "${STREAMLIT_REPO:-none}" || true)"
  for repo in $repos; do
    echo "  Deleting ECR repo ${repo}…"
    aws ecr delete-repository --repository-name "$repo" --force \
      --region "${REGION:-ca-central-1}" >/dev/null && echo "  deleted" || echo "  (failed - check by hand)"
  done
  [ -n "$repos" ] || echo "  (none present)"
else
  echo "  (no Terraform outputs - skipping)"
fi

echo "== Step 3: tofu destroy =="
tf destroy "$@"

echo
echo "Teardown complete. Sanity-check for stragglers:"
echo "  aws ec2 describe-instances --filters Name=tag:Project,Values=eks-auto-llm --query 'Reservations[].Instances[].State.Name'"
