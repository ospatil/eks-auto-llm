#!/usr/bin/env bash
# Pre-warm the ECR pull-through cache with the vLLM image, or with the
# pull-through URIs given as arguments, e.g. the NVIDIA DRA driver:
#   scripts/prewarm-image.sh "$(tofu -chdir=terraform output -raw k8s_cache_prefix)/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.5.1"
#
# The cluster has no internet egress. ECR's pull-through cache fetches from the
# upstream (public.ecr.aws) SERVER-SIDE, but to avoid any first-pull edge cases
# and to keep node IAM at PullOnly, we trigger the very first pull here from your
# laptop (which has internet + admin creds). This creates the backing cache repo
# and populates the image; nodes then pull the cached copy over VPC endpoints.
#
# Just an authenticated `docker pull` of the pull-through URI - no push. ECR does
# the heavy copy. Re-runnable (no-op once cached, until the tag rotates).
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${REGION:-ca-central-1}"
TF_DIR="terraform"

tf() { if command -v tofu >/dev/null 2>&1; then tofu -chdir="$TF_DIR" "$@"; else terraform -chdir="$TF_DIR" "$@"; fi; }

if [ "$#" -gt 0 ]; then
  IMAGES=("$@")
else
  IMAGES=("$(tf output -raw vllm_image_uri)")
fi
REGISTRY="${IMAGES[0]%%/*}"

printf 'Pull-through image: %s\n' "${IMAGES[@]}"
echo

echo "Logging in to ECR (your private registry)…"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "Pulling through the cache (ECR fetches from the upstream server-side)…"
echo "First pull populates the cache; this can take a few minutes for a large image."
for image in "${IMAGES[@]}"; do
  docker pull --platform linux/amd64 "$image"
done

echo
echo "Cache warmed. Nodes can now pull these with no internet egress."
echo "(You can 'docker rmi' them locally - the cached copies live in ECR.)"
