#!/usr/bin/env bash
# Print a spike manifest or values file with its placeholders filled in from
# the spike stack's tofu outputs and the environment. Pipe it into kubectl or
# helm; the checked-in files are never changed.
#
#   spikes/render.sh spikes/hybrid/dns-check.yaml | kubectl apply -f -
#
# Placeholders:
#   __PUB__            <registry>/<project>-pub   (ECR Public pull-through)
#   __K8S__            <registry>/<project>-k8s   (registry.k8s.io pull-through)
#   __VLLM_IMAGE__     the vLLM DLC image, through the pull-through cache
#   __HELLO_IMAGE__    $HELLO_IMAGE, printed by spikes/push-image.sh
#   __WEIGHTS_IMAGE__  $WEIGHTS_IMAGE, printed by spikes/push-image.sh
#   __SMALL_IMAGE__    $SMALL_IMAGE, printed by spikes/push-image.sh
#
# Reads the spike stack's outputs (TF_WORKSPACE defaults to spike). For a local
# test against kind, set REGISTRY, PROJECT and VLLM_IMAGE instead; Terraform is
# skipped. See spikes/local/.
set -euo pipefail

cd "$(dirname "$0")/.."
TF_DIR="terraform"
export TF_WORKSPACE="${TF_WORKSPACE:-spike}"

tf() { if command -v tofu >/dev/null 2>&1; then tofu -chdir="$TF_DIR" "$@"; else terraform -chdir="$TF_DIR" "$@"; fi; }

if [ -z "${REGISTRY:-}" ]; then
  REGISTRY="$(tf output -raw ecr_registry)"
  PROJECT="$(tf output -raw project)"
  VLLM_IMAGE="$(tf output -raw vllm_image_uri)"
fi

sed -e "s|__PUB__|${REGISTRY}/${PROJECT}-pub|g" \
    -e "s|__K8S__|${REGISTRY}/${PROJECT}-k8s|g" \
    -e "s|__VLLM_IMAGE__|${VLLM_IMAGE:-__VLLM_IMAGE_NOT_SET__}|g" \
    -e "s|__HELLO_IMAGE__|${HELLO_IMAGE:-__HELLO_IMAGE_NOT_SET__}|g" \
    -e "s|__WEIGHTS_IMAGE__|${WEIGHTS_IMAGE:-__WEIGHTS_IMAGE_NOT_SET__}|g" \
    -e "s|__SMALL_IMAGE__|${SMALL_IMAGE:-__SMALL_IMAGE_NOT_SET__}|g" "$1"
