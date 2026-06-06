---
marp: true
theme: default
paginate: true
backgroundColor: #fff
style: |
  section {
    font-size: 22px;
  }
  h1 {
    color: #232f3e;
  }
  h2 {
    color: #c7511f;
  }
  h3 {
    color: #232f3e;
  }
  table {
    font-size: 18px;
  }
  code {
    font-size: 16px;
  }
  pre {
    font-size: 14px;
  }
  img {
    background-color: #fff;
  }
---

# Serving an LLM on EKS Auto Mode

## A best-practices, air-gapped vLLM deployment

Omkar Patil

---

## The Goal

- Deploy an ~8B LLM on Amazon EKS, following best practices, and keep it operable and cheap.
- Use EKS Auto Mode so AWS manages the undifferentiated heavy lifting (nodes, drivers, add-ons).
- Treat security as the default, not an afterthought:
  - Private API endpoint (no public Kubernetes API)
  - Air-gapped data plane (no NAT, no Internet Gateway)
  - Least-privilege access via EKS Pod Identity
- Stand up from a clean account and tear down completely with one command.

### Not the goal

- A bespoke inference stack. We configure vLLM; we don't write serving code.
- A 24/7 production service. This runs on demand and scales to zero between sessions.

---

## What Gets Deployed

- **Model:** Qwen2.5-7B-Instruct (open, Apache-2.0, no HF token). Swappable.
- **Inference server:** vLLM, exposing an OpenAI-compatible API.
- **Accelerator:** one NVIDIA A10G GPU (`g5.xlarge`, falls back to `g6`).
- **Verifier:** a small Streamlit chat app, in-cluster.
- **Weights:** staged once to S3, streamed into GPU memory at runtime.

The model is a directory of files (weights + config + tokenizer), not code. vLLM loads it; everything around it is ordinary Deployments, Services, and IAM.

---

## Architecture

![Architecture](diagrams/01-architecture.svg)

---

## Design Decisions

| Area | Choice |
|------|--------|
| Cluster | EKS Auto Mode (managed Karpenter, drivers, add-ons) |
| API endpoint | Fully private; reached via a minimal SSM tunnel target |
| IaC | OpenTofu/Terraform for infra; kubectl manifests for workloads |
| Accelerator | NVIDIA A10G GPU (not Neuron; see trade-off slide) |
| Weights | Staged to S3, streamed via vLLM `runai_streamer` |
| Image | ECR pull-through cache from ECR Public (no Docker Hub) |
| Access | Pod Identity, read-only S3, scoped to one bucket |

---

## Two Layers, Two Apply Phases

- **Infra layer** (OpenTofu, AWS provider only): VPC, EKS, endpoints, IAM, S3, ECR, tunnel.
  - Applies from anywhere; only talks to AWS APIs.
- **Workload layer** (kubectl manifests): GPU NodePool, vLLM, Streamlit.
  - Applies from the laptop *through the SSM tunnel*.

Why split: a private cluster's Kubernetes API isn't reachable from outside the VPC, so the k8s/helm providers can't run from your laptop. Keeping them out of the infra state also makes `destroy` reliable.

---

# Best-Practice Building Blocks

---

## Air-Gapped Data Plane

- No NAT gateway, no Internet Gateway. The cluster has zero internet egress.
- All AWS access goes through VPC endpoints:
  - Interface: `ssm`, `ssmmessages`, `ec2messages`, `sts`, `ecr.api`, `ecr.dkr`, `eks-auth`, `eks`
  - Gateway: `s3` (model streaming + ECR layers)
- Consequence: weights and the container image must be staged out-of-band; nothing in the cluster reaches the public internet.

This is the posture you'd want for sensitive workloads, and it forces a clean separation between "what the operator does" and "what the cluster does."

---

## Private API Access (SSM Tunnel)

- The Kubernetes API is private: it resolves and accepts connections only inside the VPC.
- A minimal SSM tunnel target (small EC2, no key, no public IP, nothing installed, no cluster rights) acts purely as a TCP forwarder.

```bash
make tunnel   # SSM port-forward localhost:8443 -> <api-host>:443
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

- kubectl runs on your laptop, authenticating as your own AWS identity.
- The API cert isn't valid for `localhost`, so the script sets `tls-server-name` to the real hostname: kubectl dials the tunnel but verifies the cert against the name it's actually issued for.
- SSM can only relay through a running agent on an instance (no agentless VPC tunnel), so this one tiny instance is the minimum needed to reach a private API.

---

## Model Loading: S3 Streaming

![Data flow](diagrams/02-data-flow.svg)

---

## Model Loading: How and Why

- **Stage once** (`make stage`, on your laptop): `hf download` then `aws s3 sync` to the weights bucket. The only step that touches HuggingFace.
- **At runtime:** vLLM is started with `--model s3://<bucket>/<model>/ --load-format runai_streamer`.
  - The Run:ai Model Streamer reads safetensors from S3 straight into GPU memory.
  - Over the S3 gateway endpoint: no NAT, no internet, no local copy.
  - S3 auth is automatic via the Pod Identity role.

Consequences:

- Data plane never touches the public internet.
- The slow ~15GB download is decoupled from cluster lifecycle.
- Pod restarts and scale-ups only re-stream from S3.

---

## Image Delivery: ECR Pull-Through Cache

With no internet egress, nodes can't pull from Docker Hub.

- A pull-through rule points at ECR Public (`public.ecr.aws`), whose vLLM DLC needs no credentials.
- On a cache miss, ECR fetches the upstream image server-side from AWS IPs; the node never touches the internet.
- `make prewarm` does the first pull once from your laptop, populating the cache.
- Cluster nodes then need only `PullOnly` and pull over the `ecr.api`/`ecr.dkr` + S3 endpoints.

Result: the same air-gapped guarantee for the image as for the weights.

---

## Least-Privilege Access: Pod Identity

- The serving pod runs as the `model-storage-sa` service account.
- An IAM role trusts `pods.eks.amazonaws.com` and grants only:
  - `s3:ListBucket` + `s3:GetObject`, read-only, on the one weights bucket.
- Associated via `aws_eks_pod_identity_association`. No OIDC provider, no SA annotations; the mapping lives in the EKS control plane.
- The Pod Identity Agent is built into Auto Mode; nothing to install.

---

<style scoped>pre { font-size: 12px; } section { font-size: 20px; }</style>

## GPU NodePool

Auto Mode's built-in NodePools launch only C/M/R instances, so GPUs need a custom one (`karpenter.sh/v1`). It supplies the NVIDIA driver + device plugin; pods just request `nvidia.com/gpu`.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
spec:
  template:
    spec:
      nodeClassRef: { group: eks.amazonaws.com, kind: NodeClass, name: default }
      taints: [{ key: nvidia.com/gpu, effect: NoSchedule }]   # only vLLM tolerates this
      requirements:
        - { key: eks.amazonaws.com/instance-family, operator: In, values: [g5, g6] }
        - { key: karpenter.sh/capacity-type, operator: In, values: [on-demand] }
  disruption: { consolidationPolicy: WhenEmpty, consolidateAfter: 1m }   # scale to zero
  limits: { nvidia.com/gpu: "1" }                                        # cap at one GPU
```

- **NodeClass `default`:** built-in, AWS already wired node role / subnets / SGs / 80Gi disk.
- **Taint** keeps everything but vLLM off the expensive node; **`WhenEmpty`** removes it after the pod is gone.

---

<style scoped>pre { font-size: 12px; } section { font-size: 20px; }</style>

## vLLM Deployment

Single replica, runs as `model-storage-sa`, tolerates the GPU taint, Service named `llm-api` (not `vllm`, to dodge the `VLLM_PORT` env collision).

```yaml
containers:
  - name: vllm
    image: <ECR pull-through DLC>
    args: ["--model=s3://<bucket>/<model>/", "--load-format=runai_streamer",
           "--served-model-name=chat", "--port=8000",
           "--max-model-len=8192", "--gpu-memory-utilization=0.90"]   # fit 24GB A10G
    resources:
      requests: { cpu: "4", memory: 24Gi, nvidia.com/gpu: 1 }
      limits:   { memory: 24Gi, nvidia.com/gpu: 1 }
    volumeMounts: [{ name: shm, mountPath: /dev/shm }]
    startupProbe: { httpGet: { path: /health, port: 8000 }, failureThreshold: 60 }
volumes:
  - name: shm
    emptyDir: { medium: Memory, sizeLimit: 8Gi }   # PyTorch shared memory
```

- **24GB fit:** cap `--max-model-len` + `--gpu-memory-utilization 0.90` to leave KV-cache headroom.
- **`/dev/shm`:** PyTorch shared memory; per vLLM's k8s docs (matters most for tensor-parallel; harmless at TP=1).
- **`startupProbe`** (up to ~10 min) covers the S3 stream + graph capture before readiness/liveness.

---

## Accelerator: GPU vs AWS Neuron

| | NVIDIA GPU (chosen) | AWS Neuron |
|--|---------------------|------------|
| Cost | Baseline (~$1/hr g5.xlarge) | ~30-40% cheaper |
| Get a model running | Point vLLM at safetensors | Needs a pre-compiled artifact |
| Model availability | Anything on HuggingFace | Only compiled models (short list) |
| S3 streaming | `runai_streamer` works | Different loader, local-path only |
| Ecosystem | Large, portable | Smaller, AWS-specific |

This project uses GPU: it runs any model with no compile step. Neuron trades that flexibility for lower cost, which is worth it for steady-state production serving.
