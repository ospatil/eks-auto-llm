#!/usr/bin/env bash
# Package a directory as a FROM scratch image and push it to the spike stack's
# ECR, for mounting as an image volume. Each top-level file gets its own layer,
# so a model's safetensors shards download in parallel and no layer is larger
# than one shard. Prints the digest-pinned reference to use.
#
#   spikes/push-image.sh hello spikes/image-volume/hello
#   spikes/push-image.sh qwen2.5-7b-instruct models/Qwen2.5-7B-Instruct
#   -> <registry>/<project>/spike/<name>@sha256:...
#
# Phase 3's scripts/package-model.sh grows out of this. Repos land under
# <project>/spike/, which `make down SPIKE=1` deletes.
#
# Local test against kind: set REGISTRY (e.g. localhost:5001) and PLATFORM
# (e.g. linux/arm64); Terraform and ECR are skipped. See spikes/local/.
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${REGION:-ca-central-1}"
TF_DIR="terraform"
export TF_WORKSPACE="${TF_WORKSPACE:-spike}"

tf() { if command -v tofu >/dev/null 2>&1; then tofu -chdir="$TF_DIR" "$@"; else terraform -chdir="$TF_DIR" "$@"; fi; }

if [ "$#" -ne 2 ] || [ ! -d "$2" ]; then
  echo "usage: $0 <name> <directory>" >&2
  exit 1
fi
if ! docker buildx version >/dev/null 2>&1; then
  echo "Needs docker buildx. With Homebrew: brew install docker-buildx, then add" >&2
  echo '"cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"] to ~/.docker/config.json.' >&2
  exit 1
fi
NAME="$1"
SRC="$(cd "$2" && pwd)"
TAG="${TAG:-$(date +%Y%m%d-%H%M%S)}"
PLATFORM="${PLATFORM:-linux/amd64}"

if [ -n "${REGISTRY:-}" ]; then
  LOCAL=1
  PROJECT="${PROJECT:-local}"
else
  LOCAL=0
  REGISTRY="$(tf output -raw ecr_registry)"
  PROJECT="$(tf output -raw project)"
fi
REPO="${PROJECT}/spike/${NAME}"
IMAGE="${REGISTRY}/${REPO}:${TAG}"

if [ "$LOCAL" -eq 0 ]; then
  aws ecr describe-repositories --region "$REGION" --repository-names "$REPO" >/dev/null 2>&1 \
    || aws ecr create-repository --region "$REGION" --repository-name "$REPO" >/dev/null
fi

# One COPY per top-level entry. The Dockerfile goes in a temp dir and is passed
# with -f, so the source directory is never written to.
WORK="$(mktemp -d)"
DOCKERFILE="${WORK}/Dockerfile"
trap 'rm -rf "$WORK"' EXIT
{
  echo "FROM scratch"
  for entry in "$SRC"/*; do
    base="$(basename "$entry")"
    echo "COPY [\"${base}\", \"/${base}\"]"
  done
} > "$DOCKERFILE"

echo "Image: ${IMAGE}"
du -sh "$SRC"
if [ "$LOCAL" -eq 0 ]; then
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
fi

# --provenance=false keeps a plain single-platform manifest, not an index with
# an attestation, so the digest is the image itself.
start=$(date +%s)
docker buildx build --platform "$PLATFORM" --provenance=false \
  --metadata-file "${WORK}/metadata.json" \
  -f "$DOCKERFILE" -t "$IMAGE" --push "$SRC"
echo "Build + push took $(( $(date +%s) - start ))s"

DIGEST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["containerimage.digest"])' "${WORK}/metadata.json")"
echo
echo "Pin as: ${REGISTRY}/${REPO}@${DIGEST}"
