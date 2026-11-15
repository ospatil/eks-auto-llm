#!/usr/bin/env bash
# Open an SSM port-forward from your laptop to the PRIVATE EKS API server, then
# configure a kubeconfig context that uses the tunnel.
#
# How it works:
#   1. The private API hostname only resolves inside the VPC, and its TLS cert's
#      SAN does NOT include "localhost". So we forward a local port to the API's
#      real hostname:443 THROUGH the SSM tunnel instance
#      (AWS-StartPortForwardingSessionToRemoteHost), then point kubectl at
#      https://localhost:<port> while setting tls-server-name to the real host so
#      cert verification still passes.
#   2. kubectl/helm run on YOUR laptop, authenticating as your AWS identity
#      (cluster-admin via enable_cluster_creator_admin_permissions).
#
# Leave this running in one terminal; use kubectl in another. Ctrl-C to close.
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${REGION:-ca-central-1}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
TF_DIR="terraform"

tf() { if command -v tofu >/dev/null 2>&1; then tofu -chdir="$TF_DIR" "$@"; else terraform -chdir="$TF_DIR" "$@"; fi; }

CLUSTER="$(tf output -raw cluster_name)"
INSTANCE="$(tf output -raw bastion_instance_id)"

# Resolve the cluster's real private API endpoint hostname.
ENDPOINT="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.endpoint' --output text)"
HOST="${ENDPOINT#https://}"   # strip scheme
HOST="${HOST%%/*}"            # strip any path

echo "Cluster   : ${CLUSTER}"
echo "API host  : ${HOST}"
echo "Tunnel via: ${INSTANCE}  (local :${LOCAL_PORT} -> ${HOST}:443)"
echo

# Write/refresh a dedicated kubeconfig context that dials the tunnel.
KUBECONFIG_FILE="${KUBECONFIG_FILE:-${PWD}/kubeconfig}"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" \
  --kubeconfig "$KUBECONFIG_FILE" >/dev/null
CTX="$(kubectl --kubeconfig "$KUBECONFIG_FILE" config current-context)"
# Point at the local tunnel, but verify the cert against the real SAN.
kubectl --kubeconfig "$KUBECONFIG_FILE" config set-cluster "$(kubectl --kubeconfig "$KUBECONFIG_FILE" config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}")" \
  --server="https://localhost:${LOCAL_PORT}" >/dev/null
CLUSTER_KEY="$(kubectl --kubeconfig "$KUBECONFIG_FILE" config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}")"
kubectl --kubeconfig "$KUBECONFIG_FILE" config set "clusters.${CLUSTER_KEY}.tls-server-name" "$HOST" >/dev/null

green() { printf '\033[32m%s\033[0m\n' "$*"; }
green "kubeconfig written: ${KUBECONFIG_FILE}"
green "In another terminal run:"
green "    export KUBECONFIG=${KUBECONFIG_FILE}"
green "    kubectl get nodes"
echo
echo "Starting SSM port-forward (Ctrl-C to stop)…"
exec aws ssm start-session \
  --region "$REGION" \
  --target "$INSTANCE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${HOST}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
