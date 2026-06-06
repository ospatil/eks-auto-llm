#!/usr/bin/env bash
# Build the Streamlit chat image and push it to the private ECR repo.
# Runs from your laptop (ECR login + push go over the public ECR endpoint).
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${REGION:-ca-central-1}"
TF_DIR="terraform"
TAG="${TAG:-latest}"

tf() { if command -v tofu >/dev/null 2>&1; then tofu -chdir="$TF_DIR" "$@"; else terraform -chdir="$TF_DIR" "$@"; fi; }

REPO_URL="$(tf output -raw ecr_streamlit_repo_url)"
REGISTRY="${REPO_URL%%/*}"

echo "Repo: ${REPO_URL}:${TAG}"
echo "Logging in to ECR…"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "Building (linux/amd64 - Auto Mode nodes are amd64)…"
docker build --platform linux/amd64 -t "${REPO_URL}:${TAG}" src/streamlit

echo "Pushing…"
docker push "${REPO_URL}:${TAG}"
echo "Done: ${REPO_URL}:${TAG}"
