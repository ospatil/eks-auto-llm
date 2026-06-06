# Model Hosting Primer (for the k8s-fluent, ML-curious)

A brief tour of the LLM-serving concepts this project uses, written for someone who knows Kubernetes/EKS well but is new to model hosting. Every term is tied back to what this repo actually does. For the architecture and decisions, see [DESIGN.md](../DESIGN.md); for the runbook, see [README.md](../README.md).

## What *is* "a model"?

When we say "deploy a model," we mean shipping a directory of files - not a binary, not a service. A typical LLM repo (e.g. on HuggingFace) contains three kinds of things:

1. **Weights** - the actual learned numbers. These are huge matrices of floating-point values produced by training. For an "8B" model that's ~8 billion numbers. This is the bulk of the size (~15 GB for 8B) and what we stage to S3.
2. **Config** - small JSON describing the model's *shape* (layer count, dimensions, vocab size) so the serving software knows how to wire the weights together.
3. **Tokenizer** - the rules for turning text into the integer **tokens** the model consumes, and back again.

> **Mental model:** weights are like a container image layer (big, immutable data), config is like the manifest describing how to run it, and the tokenizer is the codec at the edges. "Loading a model" = reading these files into accelerator memory and standing up something that can answer requests.

### "Weights" and the `.safetensors` format

The weights ship as files. The modern, safe format is **`.safetensors`** (a flat, memory-mappable tensor format - no arbitrary code execution, unlike the older Python `pickle`/`.bin`/`.pth` format). This matters to us concretely: the S3-streaming loader we use (`runai_streamer`) **requires safetensors**, which is why `scripts/stage-model.sh` excludes `*.pth`/`*.gguf`.

### Loading weights from S3: the Run:ai Model Streamer

`runai_streamer` is the **third-party, open-source Run:ai Model Streamer** (from Run:ai, acquired by NVIDIA in 2024 - *not* an AWS tool). It isn't a separate process you run; it's a **loading backend built into vLLM**, selected with `--load-format runai_streamer` (shipped in the AWS vLLM image we use).

The naive way to load from object storage is two sequential steps: download all ~15 GB to local disk, *then* read it into GPU memory. The streamer **collapses these into one concurrent operation** - it reads the safetensors tensors over many parallel connections and feeds them **straight into GPU memory as they arrive**, with no full local copy and no download-then-load wait. The payoff is faster cold starts and no scratch disk.

Why it fits this project:

- **Speaks `s3://` natively** - `--model s3://bucket/path/` streams directly. This is the basis of our "weights live in S3, no local copy" approach.
- **Uses the AWS SDK's default credential chain** - so our **Pod Identity** role (read-only S3) is picked up automatically; no keys are passed to vLLM.
- Combined with the **S3 gateway VPC endpoint**, bytes travel S3 → GPU **entirely inside AWS** (no NAT, no internet) - what makes the air-gapped data plane possible.
- **Safetensors only** - it memory-maps tensors directly, so it can't read `.pth`/`.gguf`. (It's also GPU-path-specific, which is one reason the Neuron alternative uses a different loader entirely.)

### "7B / 8B" - parameters, and why they dictate hardware

The "B" is **billions of parameters** (individual weights). It's the single most important number for hardware sizing, because every parameter is a number that has to be physically stored in the accelerator's memory:

- **Memory = parameters × bytes-per-number.** Each weight is a decimal number, and how many **bits** you use to store one number is a choice. The common choice for serving is **16-bit** (2 bytes per number) - so an 8B model needs roughly 8 billion × 2 bytes ≈ **16 GB** just for weights. That has to fit in the accelerator's memory: an A10G GPU has **24 GB**, so 8B fits with headroom; a 70B model (~140 GB) would not fit on one.
- **Precision - how many bits per number** (vLLM's `--dtype` flag). More bits = more exact numbers but more memory; fewer bits = smaller but coarser.
  - **32-bit** (`fp32`, "full precision") is what models are originally trained in - most exact, but 4 bytes/number.
  - **16-bit** (`fp16` or `bf16`, "**half** precision") halves that to 2 bytes/number with negligible quality loss for inference. This is the standard default, and what we use.
  - **`fp16` vs `bf16`** are two ways to lay out those 16 bits; `bf16` ("brain float") trades a bit of fractional accuracy for a wider numeric range that's more training-stable. Both are 2 bytes - for our purposes they're interchangeable, and modern GPUs/models prefer `bf16`.
- **Quantization** goes further - squeezing each number into **8 or even 4 bits** (1 byte or ½ byte) to shrink the model so it fits on smaller/cheaper hardware. The trade-off is some loss of answer quality, since you're storing each weight more coarsely. **We don't quantize**, because an 8B model in 16-bit already fits comfortably on the 24 GB A10G - quantization is a tool for when a model is *too big* for your accelerator.

This is why the whole project revolves around a single GPU instance and an ~8B model: it's the sweet spot where one affordable accelerator serves a genuinely useful model at full 16-bit quality.

## The accelerator: GPU, CUDA, and "CUDA-standard"

An **accelerator** is the chip that does the massively-parallel math (GPUs were built for graphics; the same parallelism suits ML). 

**CUDA** is NVIDIA's proprietary software platform - the drivers, libraries, and programming API - for running general computation on NVIDIA GPUs. Because NVIDIA got there first and everyone built on it, **CUDA is the de-facto standard**: virtually every ML framework and model targets CUDA first. When I called GPU "CUDA-standard," I meant: hand it a standard model and it runs, because the entire ecosystem assumes CUDA.

In EKS terms: the GPU needs a kernel driver + a Kubernetes **device plugin** (so pods can request `nvidia.com/gpu: 1` the way they request CPU/memory). **EKS Auto Mode installs both for us** - that's a big reason we chose it.

### The Neuron contrast (and "NEFF graphs")

AWS **Neuron** (Trainium/Inferentia chips) is the cheaper, AWS-built alternative - but it is *not* CUDA-compatible. A model can't run on Neuron as-is; it must first be **compiled** by Neuron's compiler into its own format. The compiled output is a set of **NEFF** files (Neuron Executable File Format) - precompiled compute graphs, analogous to building a binary for a specific CPU architecture instead of running an interpreted script.

That compile-ahead step is the whole trade-off: Neuron is cheaper to run but you can only serve models someone has compiled (or that you compile yourself). We chose GPU to avoid it. Full comparison in [DESIGN.md](../DESIGN.md#accelerator-choice-nvidia-gpu-vs-aws-neuron).

## The inference server: what vLLM actually does

The model files are inert data. The **inference server** is the long-running process that loads them into accelerator memory and turns HTTP requests into generated text. We use **vLLM** - a high-throughput LLM serving engine. Its jobs:

- Load the weights onto the GPU and keep them resident.
- Accept requests, run the model's math to generate output tokens one at a time, and stream the results back.
- Batch many concurrent requests efficiently (its headline feature).

In k8s terms: vLLM is just the container in our `Deployment`. The "model" is data it reads at startup (from S3, in our case); the Service in front is an ordinary `ClusterIP`.

### "OpenAI-compatible API"

vLLM exposes the **same HTTP API shape as OpenAI's** (`POST /v1/chat/completions`, `GET /v1/models`, etc.). This is a de-facto standard: any client or library written for OpenAI works against vLLM by changing the base URL. The Streamlit app uses the stock `openai` Python client pointed at `http://llm-api:8000/v1`, with no custom protocol.

### Tokens, context length, and the KV cache

A few terms you'll see in the vLLM args and error messages:

- **Token** - a chunk of text (~¾ of a word). Models read and write tokens, not characters.
- **Context length** (`--max-model-len`) - the max tokens the model can consider at once (prompt + response). Bigger = more memory.
- **KV cache** - memory vLLM uses to avoid recomputing past tokens during generation. It grows with context length × concurrent requests, and it competes with the weights for GPU memory. This is why `--max-model-len 8192` and `--gpu-memory-utilization 0.90` are tuned in our deployment: if the KV cache + weights exceed 24 GB, vLLM OOMs at startup. Lowering either is the fix.

## How it all fits in this project

![How the pieces fit](diagrams/04-concepts.svg)

- **A "model"** = the safetensors weights + config + tokenizer we stage into **S3**.
- **The accelerator** = an NVIDIA **GPU** (A10G), with CUDA + device plugin handled by **Auto Mode**.
- **The inference server** = **vLLM**, serving an **OpenAI-compatible API**, which **Streamlit** chats with.

With the k8s side already familiar to you, the only new layer here is "a model is a directory of weights that must fit in accelerator memory, loaded by a serving process." Everything else is ordinary Deployments, Services, and IAM.
