#!/usr/bin/env bash
# Delete the local kind cluster and registry created by up.sh.
set -euo pipefail

cd "$(dirname "$0")"
kind delete cluster --name eks-auto-llm-local --kubeconfig "${KUBECONFIG_FILE:-$(cd ../.. && pwd)/kubeconfig-local}"
docker rm -f kind-registry >/dev/null 2>&1 && echo "Deleted kind-registry" || true
