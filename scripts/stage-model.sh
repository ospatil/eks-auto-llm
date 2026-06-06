#!/usr/bin/env bash
# OUT-OF-BAND model staging: download model weights from HuggingFace to your
# laptop, then upload to the S3 weights bucket. The cluster never contacts
# HuggingFace - it only ever reads these weights from S3 (read-only Pod Identity).
#
# Run AFTER `make up` (needs the bucket name from tofu outputs). Re-runnable;
# `aws s3 sync` only uploads changed files.
#
# Env overrides:
#   MODEL_ID   HuggingFace repo id (default: from tofu output / Qwen)
#   BUCKET     target S3 bucket   (default: from tofu output)
#   HF_TOKEN   only needed for gated models (e.g. Llama); Qwen needs none
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${REGION:-ca-central-1}"
TF_DIR="terraform"

tf() { if command -v tofu >/dev/null 2>&1; then tofu -chdir="$TF_DIR" "$@"; else terraform -chdir="$TF_DIR" "$@"; fi; }

MODEL_ID="${MODEL_ID:-$(tf output -raw model_id 2>/dev/null || echo 'Qwen/Qwen2.5-7B-Instruct')}"
BUCKET="${BUCKET:-$(tf output -raw models_bucket 2>/dev/null || true)}"

if [ -z "${BUCKET:-}" ]; then
  echo "ERROR: could not determine the S3 bucket. Run 'make up' first, or set BUCKET=..." >&2
  exit 1
fi

echo "Model : ${MODEL_ID}"
echo "Bucket: s3://${BUCKET}/${MODEL_ID}/"
echo

# Use an isolated venv so we don't pollute the user's Python environment.
VENV="$(mktemp -d)/venv"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install --quiet --upgrade pip
# huggingface_hub >=1.0 ships the `hf` CLI directly (the old `huggingface-cli`
# command and the `[cli]` extra were removed).
pip install --quiet huggingface_hub

DL_DIR="$(mktemp -d)/model"
echo "Downloading to ${DL_DIR} (this can take a while for ~15GB)…"
# --exclude pickle/original dups: vLLM's S3 streamer needs SAFETENSORS only.
# Each pattern needs its OWN --exclude flag: the `hf` CLI treats bare args after
# the repo id as explicit FILENAMES, not extra exclude patterns.
HF_TOKEN="${HF_TOKEN:-}" hf download "${MODEL_ID}" \
  --local-dir "${DL_DIR}" \
  --exclude "*.pth" \
  --exclude "original/*" \
  --exclude "*.gguf"

echo "Uploading to S3…"
aws s3 sync "${DL_DIR}" "s3://${BUCKET}/${MODEL_ID}/" --region "${REGION}" --only-show-errors

echo
echo "Done. Weights staged at s3://${BUCKET}/${MODEL_ID}/"
echo "(Local download dir ${DL_DIR} can be deleted to reclaim space.)"
