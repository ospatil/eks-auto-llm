#!/usr/bin/env bash
# Port-forward the in-cluster Streamlit app to your laptop so you can chat with
# the model in a browser. Requires the SSM tunnel active + KUBECONFIG set.
set -euo pipefail

LOCAL="${LOCAL:-8501}"
echo "Forwarding Streamlit -> http://localhost:${LOCAL}"
echo "Open that URL in your browser. Ctrl-C to stop."
echo
exec kubectl -n llm port-forward svc/streamlit "${LOCAL}:8501"
