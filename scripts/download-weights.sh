#!/usr/bin/env bash
# Download model weights from HuggingFace to your laptop, for packaging as
# images with spikes/push-image.sh. Needs no AWS credentials and no stack, so
# run it the day before a session. Re-runnable; `hf download` skips files it
# already has.
#
#   make weights
#   -> models/Qwen2.5-7B-Instruct, models/Qwen2.5-0.5B-Instruct (git-ignored)
#
# Env overrides:
#   MODELS       space-separated HuggingFace repo ids (default: the two below)
#   WEIGHTS_DIR  parent directory (default: models/ in the repo); one folder per model
#   HF_TOKEN     only needed for gated models (e.g. Llama); Qwen needs none
#   HF_HUB_DOWNLOAD_TIMEOUT  seconds before a silent connection is retried (default: 60)
set -euo pipefail

cd "$(dirname "$0")/.."
MODELS="${MODELS:-Qwen/Qwen2.5-7B-Instruct Qwen/Qwen2.5-0.5B-Instruct}"
WEIGHTS_DIR="${WEIGHTS_DIR:-models}"
# Without a read timeout, `hf download` can wait forever on a connection the
# server has already closed (seen 2026-11-15: two shards stalled for 40 min).
export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-60}"

# Use an installed `hf` if there is one, otherwise an isolated venv as in
# stage-model.sh.
if ! command -v hf >/dev/null 2>&1; then
  VENV="$(mktemp -d)/venv"
  python3 -m venv "$VENV"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  pip install --quiet --upgrade pip
  pip install --quiet huggingface_hub
fi

mkdir -p "$WEIGHTS_DIR"
for model in $MODELS; do
  dir="${WEIGHTS_DIR}/$(basename "$model")"
  echo "Downloading ${model} to ${dir}…"
  # Same excludes as stage-model.sh: safetensors only. Each pattern needs its
  # own --exclude flag.
  HF_TOKEN="${HF_TOKEN:-}" hf download "$model" \
    --local-dir "$dir" \
    --exclude "*.pth" \
    --exclude "original/*" \
    --exclude "*.gguf"
  du -sh "$dir"
done

echo
echo "Done. Push each folder during the session, for example:"
echo "  spikes/push-image.sh qwen2.5-7b-instruct ${WEIGHTS_DIR}/Qwen2.5-7B-Instruct   # from the repo root"
