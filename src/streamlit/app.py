"""Minimal Streamlit chat UI that talks to the in-cluster vLLM OpenAI endpoint.

vLLM exposes an OpenAI-compatible API, so we use the standard `openai` client
pointed at the cluster-internal vLLM Service. No API key is needed (vLLM doesn't
require one by default), but the client insists on a non-empty string.
"""
import os

import streamlit as st
from openai import OpenAI

# In-cluster service DNS; overridable for local testing.
BASE_URL = os.environ.get("VLLM_BASE_URL", "http://llm-api:8000/v1")

# Model name sent in the OpenAI `model` field on every request. It must match
# vLLM's --served-model-name (set to "chat" in k8s/vllm-deployment.yaml); a
# mismatch makes vLLM reject requests with "model not found". Read from the env
# (MODEL_NAME in k8s/streamlit.yaml) so it can track that arg without a rebuild.
MODEL = os.environ.get("MODEL_NAME", "chat")

client = OpenAI(base_url=BASE_URL, api_key="not-needed")

st.set_page_config(page_title="vLLM Chat", page_icon="💬")
st.title("💬 vLLM Chat")
st.caption(f"Model: `{MODEL}` · Endpoint: `{BASE_URL}`")

with st.sidebar:
    st.header("Settings")
    temperature = st.slider("Temperature", 0.0, 1.5, 0.7, 0.1)
    max_tokens = st.slider("Max tokens", 64, 4096, 512, 64)
    if st.button("Clear conversation"):
        st.session_state.messages = []
        st.rerun()

if "messages" not in st.session_state:
    st.session_state.messages = []

# Replay history.
for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

if prompt := st.chat_input("Ask something…"):
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        try:
            stream = client.chat.completions.create(
                model=MODEL,
                messages=st.session_state.messages,
                temperature=temperature,
                max_tokens=max_tokens,
                stream=True,
            )
            response = st.write_stream(
                chunk.choices[0].delta.content or "" for chunk in stream
            )
        except Exception as exc:  # surface connection/model errors in the UI
            response = f"⚠️ Error talking to vLLM: {exc}"
            st.error(response)

    st.session_state.messages.append({"role": "assistant", "content": response})
