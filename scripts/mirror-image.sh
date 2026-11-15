#!/usr/bin/env bash
# Mirror container images into this project's private ECR, for registries that
# an ECR pull-through cache rule can't front. Prefer a pull-through rule when
# the upstream supports one (ECR Public, registry.k8s.io, GHCR, Docker Hub,
# Quay): see terraform/ecr.tf.
#
# Runs from your laptop, which has internet access. Each image is copied with
# all its platforms and its manifest bytes unchanged, so the digest in ECR is
# the upstream digest and manifests can pin it.
#
#   scripts/mirror-image.sh quay.io/example/app:v1.2.3 [more images...]
#   -> <acct>.dkr.ecr.<region>.amazonaws.com/<project>/mirror/example/app:v1.2.3
#
# Repos are created on demand under <project>/mirror/, which `make down`
# deletes. Uses crane if installed, otherwise skopeo.
#
# Local test: set REGISTRY (e.g. localhost:5001) and PROJECT to copy into a
# plain registry; Terraform and ECR are skipped.
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${REGION:-ca-central-1}"
TF_DIR="terraform"

tf() { if command -v tofu >/dev/null 2>&1; then tofu -chdir="$TF_DIR" "$@"; else terraform -chdir="$TF_DIR" "$@"; fi; }

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <image[:tag|@digest]> [...]" >&2
  exit 1
fi

if command -v crane >/dev/null 2>&1; then
  TOOL=crane
elif command -v skopeo >/dev/null 2>&1; then
  TOOL=skopeo
else
  echo "Needs crane (brew install crane) or skopeo (brew install skopeo)." >&2
  exit 1
fi

if [ -n "${REGISTRY:-}" ]; then
  LOCAL=1
  PROJECT="${PROJECT:-local}"
else
  LOCAL=0
  REGISTRY="$(tf output -raw ecr_registry)"
  PROJECT="$(tf output -raw project)"
fi

if [ "$LOCAL" -eq 1 ]; then
  echo "Local registry ${REGISTRY}: skipping ECR login and repo creation."
elif [ "$TOOL" = crane ]; then
  echo "Logging in to ECR with crane…"
  aws ecr get-login-password --region "$REGION" | crane auth login "$REGISTRY" -u AWS --password-stdin
else
  echo "Logging in to ECR with skopeo…"
  aws ecr get-login-password --region "$REGION" | skopeo login "$REGISTRY" -u AWS --password-stdin
fi

for src in "$@"; do
  # Split off the registry host; a first part without "." or ":" is Docker Hub.
  first="${src%%/*}"
  if [ "$first" != "$src" ] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [ "$first" = localhost ]; }; then
    path="${src#*/}"
  else
    path="$src"
    [[ "$path" == */* ]] || path="library/${path}"
  fi

  # Keep the tag or digest on the destination; strip it for the repo name.
  if [[ "$path" == *@* ]]; then
    repo="${path%@*}"; ref="@${path#*@}"
  elif [[ "${path##*/}" == *:* ]]; then
    repo="${path%:*}"; ref=":${path##*:}"
  else
    repo="$path"; ref=":latest"
  fi
  dest_repo="${PROJECT}/mirror/${repo}"
  dest="${REGISTRY}/${dest_repo}${ref}"

  echo
  echo "== ${src} -> ${dest}"
  if [ "$LOCAL" -eq 0 ]; then
    aws ecr describe-repositories --region "$REGION" --repository-names "$dest_repo" >/dev/null 2>&1 \
      || aws ecr create-repository --region "$REGION" --repository-name "$dest_repo" \
           --image-scanning-configuration scanOnPush=true >/dev/null
  fi

  if [ "$TOOL" = crane ]; then
    crane copy "$src" "$dest"
    digest="$(crane digest "$dest")"
  else
    skopeo copy --all --preserve-digests "docker://${src}" "docker://${dest}"
    digest="sha256:$(skopeo inspect --raw "docker://${dest}" | shasum -a 256 | cut -d' ' -f1)"
  fi
  echo "   pin as: ${REGISTRY}/${dest_repo}@${digest}"
done
