# EKS Auto Mode + vLLM LLM Serving - Design

Deployment of an ~8B LLM on Amazon EKS Auto Mode, served via vLLM and verified with a small Streamlit chat app. The setup is private API endpoint, air-gapped data plane, and least-privilege Pod Identity, and it tears down completely so it is inexpensive to run on demand. This document records the decisions and the reasoning behind them.

## Decisions (locked)

| Area | Choice |
|---|---|
| API endpoint | **Fully private**; reached via a **minimal SSM tunnel target** + laptop kubectl |
| Weight staging | **Out-of-band** local script (laptop → S3); cluster never pulls from HF |
| IaC | **OpenTofu/Terraform** for infra; plain **kubectl manifests** for workloads (two layers) |
| Model / GPU | ~7-8B model on a single **A10G** (`g5.xlarge`/`g6.xlarge`), no quantization |
| Model weights | Staged in **S3**, pulled privately via vLLM's native `s3://` streamer |
| Default model | **Qwen/Qwen2.5-7B-Instruct** (open, Apache-2.0, no HF gating) |
| Region | **ca-central-1** (assume the terminal's AWS account), 2 AZs |
| Streamlit | Build image → **private ECR** repo (created by tofu) |
| vLLM image | **ECR pull-through cache** from ECR Public (AWS vLLM DLC, no auth); pre-warmed |
| GPU quota | Unknown → **preflight checks** the G-instance vCPU service quota |

### Why Qwen2.5-7B as the default

Llama-3.1-8B is gated (HF license acceptance + token). The default is the open Qwen model so first run needs no HF token. The staging script is parameterized, so switching to Llama (with a token) is a one-line change, documented in the README.

## Architecture

![Architecture](docs/diagrams/01-architecture.png)

**Data flows**

- *Staging (one-time, out-of-band):* `scripts/stage-model.sh` on your laptop pulls weights from HuggingFace and `aws s3 sync`s them to S3. The cluster never contacts HuggingFace.
- *Image cache pre-warm (one-time, out-of-band):* `scripts/prewarm-image.sh` does the first pull of the vLLM DLC through the ECR pull-through cache (the cluster can't reach Docker Hub; the AWS DLC on ECR Public needs no auth and ECR fetches it server-side).
- *Runtime:* vLLM pulls its (now-cached) image from ECR over the interface endpoints and streams safetensors from S3 over the **S3 gateway endpoint** directly into GPU memory via `--load-format runai_streamer`. The runai S3 loader handles its own fetching and needs no internet; `HF_HUB_OFFLINE` is deliberately not set (it breaks s3:// loading; see README Troubleshooting).
- *Access:* SSM port-forward :443 to the private API; kubectl runs **on the laptop** (the tunnel script sets `tls-server-name` to satisfy the cert SAN).
- *Verify:* port-forward Streamlit (8501) through the tunnel to your laptop, chat with the model.

The full lifecycle is shown in the [lifecycle diagram](docs/diagrams/03-lifecycle.png); the weights/image staging split is in the [data-flow diagram](docs/diagrams/02-data-flow.png).

## Repo layout

```
eks-auto-llm/
├── DESIGN.md                  # this file
├── README.md                  # step-by-step runbook (spin up → verify → tear down)
├── Makefile                   # one-touch: make up / stage / prewarm / deploy / verify / down
├── terraform/                 # OpenTofu/Terraform - INFRA layer (run from anywhere)
│   ├── versions.tf            # provider pins (aws only; no k8s/helm providers here)
│   ├── variables.tf           # region, cluster_name, model_id, vllm_image_tag, etc.
│   ├── vpc.tf                 # vpc module - private subnets only, NO NAT/IGW, subnet tags
│   ├── endpoints.tf           # VPC endpoints (ssm*, ecr*, s3 gw, sts, eks-auth, eks)
│   ├── eks.tf                 # eks module ~> 21 - Auto Mode, PRIVATE endpoint
│   ├── bastion.tf             # minimal SSM tunnel target (no key/IP, no cluster rights)
│   ├── iam_pod_identity.tf    # IAM role (trust pods.eks.amazonaws.com) + S3 READ + association
│   ├── s3.tf                  # model-weights bucket (force_destroy=true)
│   ├── ecr.tf                 # Streamlit repo + vLLM pull-through cache rule (ECR Public)
│   └── outputs.tf             # tunnel id, bucket, cluster, ECR repos, model/vllm tags
├── k8s/                       # WORKLOADS layer (applied from laptop through the tunnel)
│   ├── gpu-nodepool.yaml      # karpenter.sh/v1 NodePool (A10G), built-in default NodeClass
│   ├── namespace.yaml         # namespace + serviceaccount model-storage-sa (Pod Identity)
│   ├── vllm-deployment.yaml   # vLLM Deployment+Service, s3:// streamer, GPU, offline env, probes
│   └── streamlit.yaml         # Streamlit Deployment+Service (image from src/streamlit)
├── src/
│   └── streamlit/             # chat app source: app.py, Dockerfile, requirements.txt
├── scripts/
│   ├── preflight.sh           # creds, tooling, GPU quota
│   ├── stage-model.sh         # out-of-band HF → S3 weight staging (laptop)
│   ├── prewarm-image.sh       # warm the ECR pull-through cache with the vLLM image (laptop)
│   ├── build-streamlit.sh     # build + push Streamlit image → ECR
│   ├── tunnel.sh              # SSM port-forward to private API + kubeconfig
│   ├── deploy.sh              # template + apply workloads
│   ├── verify.sh              # port-forward Streamlit to localhost:8501
│   ├── destroy.sh             # cluster cleanup then tofu/terraform destroy
│   └── export-diagrams.sh     # diagrams/*.drawio → docs/diagrams/*.png
└── diagrams/                  # hand-drawn .drawio sources
```

## Infra layer details (OpenTofu)

- **VPC** (`terraform-aws-modules/vpc ~> 5.13`):
  - 2 AZs, private subnets only. No NAT, no Internet Gateway (air-gapped data plane).
  - Subnet tag `kubernetes.io/role/internal-elb=1` for Auto Mode internal LB placement.
  - `enableDnsHostnames/Support=true`, required for the EKS-managed private hosted zone.
- **EKS** (`terraform-aws-modules/eks ~> 21`):
  - `compute_config = { enabled = true, node_pools = ["general-purpose","system"] }`.
  - `endpoint_public_access = false`, `endpoint_private_access = true`.
  - `authentication_mode = "API"` (access entries), `enable_cluster_creator_admin_permissions = true`.
  - Module creates the Auto Mode cluster + node IAM roles with the correct minimal policies.
- **VPC endpoints:**
  - Interface: `ssm`, `ssmmessages`, `ec2messages`, `sts`, `ecr.api`, `ecr.dkr`, `eks-auth` (mandatory for Pod Identity privately), `eks`.
  - Gateway: `s3` (ECR layers + model streaming). Private DNS enabled on all.
- **SSM tunnel target** (not a full bastion):
  - `t3.small`, private subnet, no public IP, no SSH key, nothing installed, no cluster access.
  - Instance profile = only `AmazonSSMManagedInstanceCore`.
  - Sole job: in-VPC target for `AWS-StartPortForwardingSessionToRemoteHost` to reach the private API on 443.
  - kubectl runs on the laptop, authenticating as the identity that ran `apply` (cluster-admin via `enable_cluster_creator_admin_permissions`).
  - The API cert isn't valid for `localhost`, so the script sets `tls-server-name` in kubeconfig to the real hostname; kubectl dials the tunnel but verifies the cert against the name it's issued for.
  - SSM can only relay through a running agent on an instance, so this one tiny instance is the minimum needed to reach a private API. (CloudShell-in-VPC is the instance-less fallback for ad-hoc kubectl.)
- **Pod Identity:**
  - IAM role trusting `pods.eks.amazonaws.com` (`sts:AssumeRole` + `sts:TagSession`).
  - Policy = `s3:ListBucket` + `s3:GetObject` (read-only) on the weights bucket only.
  - Associated to `model-storage-sa` via `aws_eks_pod_identity_association`.
  - Pod Identity Agent is built into Auto Mode; nothing to install.
- **S3 bucket:** versioning off, `force_destroy = true` so `tofu destroy` removes weights cleanly.

> **Two-phase apply:** the Kubernetes API isn't reachable from your laptop on a private cluster, so infra (AWS provider only) applies from anywhere; workloads apply from the laptop through the SSM tunnel. This split is also what makes teardown reliable.

## Workloads layer details

- **GPU NodePool** (`karpenter.sh/v1`):
  - Requirements: `eks.amazonaws.com/instance-family In [g5, g6]`, `karpenter.sh/capacity-type In [on-demand]`, arch amd64.
  - Taint `nvidia.com/gpu:NoSchedule` so only GPU workloads land there.
  - References the built-in `default` NodeClass (correct node role/subnet/SG selectors, 80Gi ephemeral storage).
  - Scales to zero when idle. Auto Mode supplies NVIDIA drivers + device plugin.
- **Stage-model** (out-of-band, not a k8s Job): `scripts/stage-model.sh` on your laptop:
  - `pip install huggingface_hub`, `hf download $MODEL_ID`, then `aws s3 sync` to `s3://$BUCKET/$MODEL_ID/` with your own AWS creds.
  - Cluster never contacts HuggingFace; the Pod Identity role is read-only.
  - HF token only needed for gated models (Qwen needs none).
  - Decouples the ~15GB download from cluster lifecycle and keeps the data plane off the internet.
- **vLLM Deployment:**
  - Image: AWS vLLM DLC via the ECR pull-through cache (pinned tag; no Docker Hub access).
  - Args: `--model s3://$BUCKET/$MODEL_ID/ --load-format runai_streamer --served-model-name chat --max-model-len 8192 --gpu-memory-utilization 0.90 --tensor-parallel-size 1`.
  - No `HF_HUB_OFFLINE`/`TRANSFORMERS_OFFLINE` (they break s3:// loading in vLLM 0.22.0; see Troubleshooting in the README).
  - `nvidia.com/gpu: 1` limit, toleration for the GPU taint.
  - **Shared memory:** an `emptyDir{medium: Memory}` mounted at `/dev/shm` (we set `sizeLimit: 8Gi`).
    - PyTorch (under vLLM) uses `/dev/shm` to share data between processes. The container default is small (~64Mi), which PyTorch can exhaust.
    - This is vLLM's documented Kubernetes pattern: their k8s deployment example mounts the same `emptyDir{medium: Memory}` at `/dev/shm` ([docs.vllm.ai/.../deployment/k8s](https://docs.vllm.ai/en/latest/deployment/k8s.html); the Docker equivalent is `--ipc=host`/`--shm-size`).
    - It matters most for tensor-parallel (multi-GPU) inference. We run TP=1, so it's not strictly required, but vLLM's single-GPU examples still include it and it's harmless headroom.
    - Size note: vLLM's NVIDIA example uses `2Gi`; we use `8Gi` (a cap on a 24GB+ node, not a reservation).
  - Probes: `startupProbe` on `/health` (generous failureThreshold for load time) + readiness + liveness.
  - ClusterIP Service `llm-api` on 8000 (not named `vllm`, to avoid the `VLLM_PORT` env collision). SA = `model-storage-sa`.
- **Streamlit app:**
  - Minimal `app.py` using the OpenAI client pointed at `http://llm-api:8000/v1`.
  - Built as an image, pushed to a private ECR repo (created in tofu), from your laptop.
  - ClusterIP Service on 8501. Verified via kubectl port-forward through the SSM tunnel.

## Preflight: GPU quota in ca-central-1

`scripts/preflight.sh` checks aws creds / tofu / session-manager-plugin, plus the GPU quota:

- Queries the "Running On-Demand G and VT instances" quota (`aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA`).
- A `g5.xlarge` needs 4 vCPUs; fresh accounts often have this at 0.
- If too low, it prints the `request-service-quota-increase` command (approval can take ~a day).
- ca-central-1 has g5 (A10G) capacity; g6 availability is thinner, so the NodePool lists `g5` first.

## Lifecycle (Makefile targets)

| Target | Action |
|---|---|
| `make preflight` | check aws creds, tooling, GPU quota |
| `make up` | init + apply (infra) |
| `make stage` | out-of-band HF→S3 weight staging (laptop) |
| `make prewarm` | warm the ECR pull-through cache with the vLLM image |
| `make image` | build + push the Streamlit image to ECR |
| `make tunnel` | open SSM tunnel to the private API (own terminal) |
| `make deploy` | apply GPU NodePool + vLLM + Streamlit (through tunnel) |
| `make verify` | port-forward Streamlit to localhost:8501 |
| `make down` | cluster cleanup, then destroy |
| `make diagrams` | export `diagrams/*.drawio` → `docs/diagrams/*.png` |

## Teardown safety

1. `kubectl delete` any LoadBalancer/Ingress objects + the `llm` namespace + GPU NodePool (releases the GPU node). This stack uses only ClusterIP, so usually no LBs to wait on.
2. Delete the **auto-created pull-through cache repo** (`ecr-public/…`) - ECR creates it on first pull, so Terraform doesn't track it and `destroy` won't remove it.
3. `destroy` - `force_destroy` bucket + `force_delete` Streamlit ECR repo; Auto Mode self-cleans its EC2/ENI/SG/LB via its service-linked role. No NAT/IGW to orphan.
4. Verify no orphaned instances/ENIs before declaring done.

## Cost notes

- A10G `g5.xlarge` ≈ $1/hr + EKS control plane $0.10/hr + Auto Mode EC2 surcharge + SSM tunnel instance (~$0.02/hr) + VPC interface endpoints (~$0.01/hr each × ~8).
- **No NAT** (removed), so ~$1.25-1.50/hr all-in with the GPU running; idle-but-up is just endpoints + tunnel (a few cents/hr). Tear down when not in use.

## Cross-validation against the AWS EKS Workshop

Validated against the AWS EKS Workshop chatbot module ([eksworkshop.com/docs/aiml/chatbot](https://www.eksworkshop.com/docs/aiml/chatbot/)). The workshop is non-Auto-Mode and Neuron-based; below is what carries over and where we deliberately differ.

| Aspect | AWS Workshop | This project | Rationale |
|---|---|---|---|
| Accelerator | Trainium/Inferentia (`trn1.2xlarge`/`inf2.xlarge`) | NVIDIA A10G (`g5`/`g6`) | GPU = standard safetensors, no Neuron compile step, broadest model compatibility. Neuron is cheaper but adds a compile/artifact step. |
| Inference server | vLLM (OpenAI API) | vLLM (OpenAI API) | **Same** - AWS uses vLLM too. |
| vLLM image | `public.ecr.aws/neuron/pytorch-inference-vllm-neuronx` | `public.ecr.aws/deep-learning-containers/vllm` | Both are AWS-hosted ECR Public images (no Docker Hub, no auth). |
| Model source | HuggingFace Hub via init container | Staged to **our own S3**, streamed via `runai_streamer` | Workshop uses `emptyDir` + re-downloads on every restart; our S3 path is repeatable, faster on restart, and needs **no cluster internet** (required for our air-gapped VPC). |
| Weight caching | None (`emptyDir`) | S3 (persistent) | - |
| Node provisioning | Manual Karpenter NodePool + LB controller install | Auto Mode (managed) | Fewer moving parts. |

**Key takeaway on model sourcing:** AWS does **not** provide an S3 bucket of weights, and does **not** mandate HuggingFace. The workshop pulls from HF - including AWS's own `aws-neuron/…` org, which hosts **Neuron-precompiled** artifacts (relevant only to Trainium/Inferentia, not GPU). For GPU/safetensors, the AWS-recommended S3-streaming pattern (`--load-format runai_streamer`, documented in the EKS "Load & Serve Models" user guide) is what we use - staging the weights into our own S3 bucket. Our design is consistent with AWS guidance and improves on the workshop's caching and air-gap properties.

## Accelerator choice: NVIDIA GPU vs AWS Neuron

The biggest fork in "optimal model hosting on EKS" is which accelerator to serve on. We chose NVIDIA GPU; this section records the trade-off so the decision is reviewable.

### The conceptual difference

> New to these terms (CUDA, safetensors, NEFF, weights)? The [Model Hosting Primer](docs/model-hosting-primer.md) explains them from a k8s/EKS perspective.

- **NVIDIA GPU** (`g5`/`g6` = A10G/L4) is the industry-standard AI accelerator. Frameworks target CUDA first, and a GPU runs a model **as-is** - you hand vLLM standard safetensors and it serves.
- **AWS Neuron** (`inf2` = Inferentia2, `trn1` = Trainium) is AWS's own purpose-built inference silicon, with its own software stack (driver + compiler + runtime). The defining constraint: a model must be **compiled ahead of time** into Neuron's format (NEFF graphs) by the Neuron compiler before it can run - analogous to building a binary for a specific target rather than running an interpreted script.

That compile-ahead requirement drives every other difference.

### Comparison

| | NVIDIA GPU (chosen) | AWS Neuron |
|---|---|---|
| Cost | Baseline (~$1/hr `g5.xlarge`) | ~30-40% cheaper for equivalent inference |
| Getting a model running | Point vLLM at safetensors → done | Needs a **pre-compiled** artifact, or self-compile (~15 min, needs the Neuron toolchain + internet) |
| Model availability | Any model on HuggingFace | Only compiled models. AWS publishes a short list (Mistral-7B, a few Qwen3); our default Qwen2.5-7B is **not** among them |
| Weight loading (this project's S3 pattern) | ✅ `runai_streamer` streams `s3://` → GPU memory | ❌ different loader (NeuronX Distributed Inference), local-path only - would need an init-container `aws s3 sync` from S3 first |
| Air-gap (no cluster internet) | ✅ stream from our S3 | ✅ achievable, but must stage **both** safetensors **and** matching NEFF artifacts to S3 (a missing/mismatched artifact makes the loader fall back to HF download + on-device compile, which need internet) |
| EKS Auto Mode support | ✅ auto-installs NVIDIA driver + device plugin | ✅ Auto Mode **also** auto-installs Neuron driver + device plugin (still need a Neuron NodePool) |
| Ecosystem / docs | Large, portable skills | Smaller, AWS-specific |

### Why GPU for this project

The goal is learning EKS model hosting on a cluster that spins up and tears down cleanly. For that, GPU is the better default: it serves any model, the path is simpler, and the skills transfer beyond AWS. Neuron's advantage is price-performance, which accrues over steady-state production runtime; its costs (ahead-of-time compilation, narrow model choice, AWS-specific tooling) are paid up front. For a cluster that's run on demand rather than 24/7, GPU wins on balance. The useful thing Neuron teaches (AWS has a cheaper accelerator with a compile-ahead model) is captured in this comparison without paying that cost.

### What switching to Neuron would entail

If optimizing for steady-state cost of a Neuron-supported model later:

- Neuron NodePool: `inf2`/`trn1` + `aws.amazon.com/neuron` taint, `aws.amazon.com/neuron: 1` requests.
- Image: `public.ecr.aws/neuron/pytorch-inference-vllm-neuronx` (also via the pull-through cache, no auth).
- A pre-compiled model repo (e.g. `aws-neuron/Mistral-7B-Instruct-v0.3-…` or self-compiled) staged to S3.
- An init container to `aws s3 sync` it to a local path (Neuron's loader is local-path only, not `s3://`).
- `vllm serve /models --device neuron --tensor-parallel-size <cores>` with `NEURON_COMPILED_ARTIFACTS` set.
- Neuron has its own service quota (separate from the G/VT GPU quota) and its own `inf2`/`trn1` regional availability to check.

## Key uncertainties to validate during build

- `instance-gpu-name` value for A10G (expected `a10g`); confirm via node labels post-launch.
- vLLM pinned-version flag names for the Run:ai streamer (verify against the chosen tag).
- vLLM **DLC tag** rotates - verify a current one in the ECR Public Gallery; confirm the DLC entrypoint accepts the same `vllm serve` args.
- Docker Hub-vs-ECR-Public first-pull internet caveat is sidestepped by `make prewarm` (first pull from the laptop) - nodes only do cached pulls.
- ✓ terraform-aws-modules/eks v21 input/output names - confirmed via `terraform validate`.
