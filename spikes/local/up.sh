#!/usr/bin/env bash
# Start the local kind cluster and registry for spikes/local/verify.sh.
# Needs docker, kind, kubectl, crane. Nothing touches AWS.
#
#   spikes/local/up.sh      # create (re-runnable)
#   spikes/local/down.sh    # delete both
set -euo pipefail

cd "$(dirname "$0")"
CLUSTER="eks-auto-llm-local"
REG_NAME="kind-registry"
REG_PORT="${REG_PORT:-5001}"
export KUBECONFIG="${KUBECONFIG_FILE:-$(cd ../.. && pwd)/kubeconfig-local}"

if [ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null || true)" != "true" ]; then
  echo "Starting registry ${REG_NAME} on localhost:${REG_PORT}…"
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --name "$REG_NAME" registry:2 >/dev/null
fi

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config kind-config.yaml --kubeconfig "$KUBECONFIG"
fi

# Nodes reach the registry as kind-registry:5000 on the kind network; map
# localhost:<port> to it so image references are the same inside and out.
docker network connect kind "$REG_NAME" 2>/dev/null || true
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${REG_PORT}"
  printf '[host."http://%s:5000"]\n' "$REG_NAME" \
    | docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/localhost:${REG_PORT}/hosts.toml"
done

kubectl get nodes -L eks.amazonaws.com/compute-type,eks-auto-llm/gpu -o wide
echo
echo "export KUBECONFIG=${KUBECONFIG}"
