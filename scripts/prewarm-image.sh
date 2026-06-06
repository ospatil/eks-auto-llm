#!/usr/bin/env bash
# Pre-warm the ECR pull-through cache with the vLLM image.
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

IMAGE_URI="$(tf output -raw vllm_image_uri)"
REGISTRY="${IMAGE_URI%%/*}"

echo "Pull-through image: ${IMAGE_URI}"
echo

echo "Logging in to ECR (your private registry)…"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "Pulling through the cache (ECR fetches from public.ecr.aws server-side)…"
echo "First pull populates the cache; this can take a few minutes for a large image."
docker pull --platform linux/amd64 "$IMAGE_URI"

echo
echo "Cache warmed. Nodes can now pull ${IMAGE_URI} with no internet egress."
echo "(You can 'docker rmi ${IMAGE_URI}' locally - the cached copy lives in ECR.)"
