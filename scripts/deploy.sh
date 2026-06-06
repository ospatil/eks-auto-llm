#!/usr/bin/env bash
# Apply the workloads to the cluster. Run with the SSM tunnel active and
# KUBECONFIG pointing at ./kubeconfig (see scripts/tunnel.sh).
#
# Templates the placeholders in the manifests from tofu outputs:
#   __MODEL_S3_URI__   -> s3://<bucket>/<model_id>/
#   __VLLM_IMAGE__     -> the ECR pull-through-cache URI (vllm_image_uri output)
#   __STREAMLIT_IMAGE__-> <ecr_streamlit_repo>:<tag>
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${REGION:-ca-central-1}"
TF_DIR="terraform"
TAG="${TAG:-latest}"
KUBECTL="kubectl"

tf() { if command -v tofu >/dev/null 2>&1; then tofu -chdir="$TF_DIR" "$@"; else terraform -chdir="$TF_DIR" "$@"; fi; }

# Sanity: are we actually talking to the cluster (tunnel up)?
if ! $KUBECTL get ns >/dev/null 2>&1; then
  echo "ERROR: kubectl can't reach the cluster. Is the tunnel running and KUBECONFIG set?" >&2
  echo "  Terminal 1:  make tunnel" >&2
  echo "  Terminal 2:  export KUBECONFIG=$PWD/kubeconfig" >&2
  exit 1
fi

BUCKET="$(tf output -raw models_bucket)"
MODEL_ID="$(tf output -raw model_id)"
STREAMLIT_REPO="$(tf output -raw ecr_streamlit_repo_url)"
MODEL_S3_URI="s3://${BUCKET}/${MODEL_ID}/"
STREAMLIT_IMAGE="${STREAMLIT_REPO}:${TAG}"
VLLM_IMAGE="$(tf output -raw vllm_image_uri)"

echo "Model S3 URI   : ${MODEL_S3_URI}"
echo "vLLM image     : ${VLLM_IMAGE}"
echo "Streamlit image: ${STREAMLIT_IMAGE}"
echo

# Base resources.
$KUBECTL apply -f k8s/namespace.yaml
$KUBECTL apply -f k8s/gpu-nodepool.yaml

# Templated resources (render to a temp file; never mutate the checked-in YAML).
render() {
  sed -e "s|__MODEL_S3_URI__|${MODEL_S3_URI}|g" \
      -e "s|__VLLM_IMAGE__|${VLLM_IMAGE}|g" \
      -e "s|__STREAMLIT_IMAGE__|${STREAMLIT_IMAGE}|g" "$1"
}
render k8s/vllm-deployment.yaml      | $KUBECTL apply -f -
render k8s/streamlit.yaml | $KUBECTL apply -f -

echo
echo "Applied. Watch rollout:"
echo "  kubectl -n llm get pods -w"
echo "vLLM cold start pulls a GPU node (~2 min) + streams weights - be patient."
