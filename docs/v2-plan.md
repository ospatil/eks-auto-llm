# v2 plan: shared GPU, weights as images, inference-aware gateway

Written 2026-11-12, to be executed later on the `v2` branch. The `v1` tag marks the working v1. Read [README.md](../README.md) and [DESIGN.md](../DESIGN.md) first.

## Status (2026-11-15)

Phase 0 prep and local verification are done; nothing has been applied to AWS yet. Details are in [lab-log.md](./lab-log.md) and the runbook in [spikes/README.md](../spikes/README.md).

- Done in code, behind `enable_gpu_node_group` (off for the real stack): Kubernetes 1.37, the `gpu` node group with Bottlerocket's device plugin off, the add-ons and the `ec2` endpoint. `gpu_ami_type` can switch the node group to AL2023 if the DRA driver can't find Bottlerocket's NVIDIA driver.
- The spike stack is `SPIKE=1` on any `make` target (own workspace, `terraform/spike.tfvars`, own project name).
- Verified offline: `make test` (plan tests with mocked AWS) and `spikes/local/verify.sh` on kind (33 checks).

**Not blocked.** The GPU vCPU quota in ca-central-1 is now 4 (approved 2026-11-15). The cloud spike is planned for one sitting in the week of 2026-11-16, estimated at $7–10 (breakdown in the lab log).

**To resume:**

1. The day before: download the weights to the laptop (see "Before the session" in [spikes/README.md](../spikes/README.md#before-the-session)), so the download isn't on the clock.
2. Log in to AWS, then `make preflight`. Optional re-check: `make test`.
3. With the owner's go-ahead: `make up SPIKE=1` and follow the [one-sitting order](../spikes/README.md#one-sitting-order). The GPU goes on only after the images are pushed, and back to 0 as soon as spike 3 is done.
4. Record results and the hours in the lab log, then `make down SPIKE=1` the same day.

## What v2 changes

v1 runs one model on one GPU in an Auto Mode cluster, streams the weights from S3, and has no gateway. v2 keeps the offline cluster and changes four things:

1. **Kubernetes 1.37,** the latest on EKS. Image volumes and DRA need 1.36 or later.
2. **A chat model and a small embedding model sharing one A10G,** with real memory limits per pod. This needs a managed node group for the GPU, because Auto Mode can't partition a GPU.
3. **Model weights shipped as OCI images** in ECR and mounted as image volumes, instead of streamed from S3.
4. **agentgateway with the Gateway API Inference Extension** in front of both models, routing by the request's `model` field. Istio is an optional comparison at the end.

```
laptop ──tunnel──▶ Gateway (agentgateway, internal)
                     ├─ model=chat  ─▶ InferencePool chat  ─▶ vLLM Qwen2.5-7B   ┐ one A10G on a managed
                     └─ model=embed ─▶ InferencePool embed ─▶ vLLM embed model  ┘ node group, shared via MPS
weights: ECR (OCI image) ──image volume──▶ /models (read-only)
```

## What we checked before planning (2026-11-12)

These were true on the date above. Re-check anything that has moved before building on it.

- **EKS supports Kubernetes 1.37** since 2026-10-02. ([AWS](https://aws.amazon.com/about-aws/whats-new/2026/10/amazon-eks-distro-kubernetes-version-1-37/))
- **Auto Mode supports DRA for NVIDIA GPUs on 1.36+, but not GPU sharing.** The NVIDIA DRA driver is built in, but time-slicing and MIG are not available. The only way to share is several pods referencing one `ResourceClaim`, with no isolation. That is why v2 moves the GPU to a managed node group. ([AWS announcement](https://aws.amazon.com/about-aws/whats-new/2026/11/amazon-eks-auto-mode-karpenter-dra/), [EKS device management](https://docs.aws.amazon.com/eks/latest/userguide/device-management.html))
- **The A10G has no MIG.** On a node group we install the NVIDIA DRA driver ourselves, which offers time-slicing and MPS. MPS caps each pod's GPU memory and compute share, but it is alpha (`MPSSupport` feature gate). ([NVIDIA DRA driver](https://dra-driver-nvidia-gpu.sigs.k8s.io/docs/concepts/gpu-allocation/))
- **Image volumes are GA in Kubernetes 1.36.** `subPath` needs containerd 2.2. Bottlerocket's 1.36 variants ship containerd 2.2; its 1.35 variants were on 2.1 until v1.64.0. Auto Mode runs its own Bottlerocket variant, so check it. ([Bottlerocket #4755](https://github.com/bottlerocket-os/bottlerocket/issues/4755))
- **The Gateway API Inference Extension is GA with `InferencePool` v1.** Since v1.6 the full endpoint picker (EPP) and body-based routing live in llm-d (`llm-d-router`); the upstream repo keeps only a conformance EPP. ([releases](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases))
- **Istio supports the extension in beta,** switched on with a pilot flag.

## Ground rules

1. **v1 stays reproducible.** Don't move or rewrite the `v1` tag. `main` keeps v1 until v2 is merged.
2. **The data plane stays offline.** No NAT, no internet gateway, no public API. Every new image comes from ECR: through a pull-through cache rule where the upstream supports it (ECR Public, `registry.k8s.io`, GHCR, Docker Hub, Quay), otherwise mirrored from the laptop.
3. **Teardown stays complete.** `make down` leaves nothing behind, including node groups, mirrored repositories and model image repositories.
4. **One GPU, ever.** The GPU node group is capped at one node. Two models share it; they never get two.
5. **No account IDs, profile names, hostnames or secrets** in the repo, docs, screenshots or commits. The repo is public.
6. **Keep the existing gotchas:** the Service is not named `vllm`; check the vLLM image tag in the ECR Public Gallery; GPU quota is the usual blocker.
7. **Record what you learn** in `docs/lab-log.md`: date, what was built, what broke, timings, cost.
8. Small commits on the `v2` branch. Don't push or create cloud resources without the owner's go-ahead.

## Phase 0: spikes

Prove the three risky assumptions on a throwaway cluster before changing the real stack. Each spike ends in a go or no-go recorded in the lab log.

- [ ] **Hybrid cluster.** Add a managed node group to a private Auto Mode cluster with no NAT and confirm its nodes join. Expect to need the `vpc-cni`, `kube-proxy` and `eks-pod-identity-agent` EKS add-ons (Auto Mode clusters don't run them), and possibly an `ec2` VPC endpoint for the CNI. Confirm the add-ons don't disturb Auto Mode nodes.
- [ ] **Image volumes.** Build a tiny `FROM scratch` image holding one file, push it to ECR, and mount it with `subPath` on both an Auto Mode node and a Bottlerocket NVIDIA 1.37 node-group node. Then push a ~15 GB weights image and time the pull through the VPC endpoints.
- [ ] **MPS on the A10G.** Install the NVIDIA DRA driver on the GPU node with `MPSSupport` enabled. Run two pods on one MPS-shared claim with different memory limits, and confirm with `nvidia-smi` that each is capped. Then run two small vLLM instances the same way. If MPS fails, repeat with time-slicing and note what is lost.
- **Done when:** each spike has a result and the timings in the lab log, and the owner has decided go or no-go for each feature.

## Phase 1: Kubernetes 1.37 and a GPU node group

- [x] Set `kubernetes_version` to `1.37`. v2 creates fresh clusters only; an in-place upgrade from 1.33 would take four one-version steps and isn't worth it for a disposable lab.
- [x] Add a managed node group `gpu`: Bottlerocket NVIDIA variant, `g5.xlarge`, min 0, max 1, desired 0, taint `nvidia.com/gpu:NoSchedule`, a label to select it, and a root/data volume large enough for the vLLM image plus two model images (start at 100 GiB).
- [x] Turn off Bottlerocket's bundled NVIDIA device plugin on that group (look up the exact Bottlerocket setting), because the DRA driver and the device plugin must not manage the same GPU. (`settings.kubelet-device-plugins.nvidia.enabled = false`, Bottlerocket 1.63.0+.)
- [ ] Add the EKS add-ons and any endpoints Phase 0 showed are needed. (`vpc-cni`, `kube-proxy`, `eks-pod-identity-agent` and `ec2` are in, behind the flag; Phase 0 confirms or adds to them.)
- [ ] Remove the Auto Mode GPU NodePool. Auto Mode keeps running everything else.
- [ ] Change `make scale-up` and `make scale-down` to set the node group's desired size to 1 or 0. (`make gpu-nodes N=0|1` exists; the scale targets still drive the Auto Mode deployments.)
- [ ] Note in DESIGN.md that node-group nodes carry no Auto Mode surcharge, and that we now own their AMI updates.
- **Done when:** a fresh `make up` gives a 1.37 cluster with an empty GPU node group, `make scale-up` brings up a GPU node that joins, and `make down` removes it all.

## Phase 2: the NVIDIA DRA driver

- [x] Find where the driver chart's images live. Use a pull-through rule if the registry is supported; otherwise add `scripts/mirror-image.sh` (laptop, `skopeo` or `crane`, digest-preserving) and mirror them. Keep the script generic; the gateway images in Phase 5 use it too. (One image on `registry.k8s.io`, through a new pull-through rule. `scripts/mirror-image.sh` exists for Phase 5.)
- [ ] Install the driver with Helm on the GPU node group only, with the `MPSSupport` gate if Phase 0 said go. This is the first Helm install in the repo; add `helm` to preflight. (`helm` is in preflight; values are in `spikes/mps/dra-values.yaml`.)
- [ ] Switch the vLLM pod from `nvidia.com/gpu: 1` to a DRA claim.
- **Done when:** the v1 chat model serves through a DRA claim on the node group, and nothing requests `nvidia.com/gpu`.

## Phase 3: weights as OCI images

- [ ] `scripts/package-model.sh`: take a staged model directory, build a `FROM scratch` image containing it, and push it to a private ECR repository such as `models/qwen2.5-7b-instruct`, tagged with the Hugging Face commit. Print the digest.
- [ ] Mount it in the vLLM pod as an `image` volume referenced **by digest**, read-only, at `/models/<name>`. Point `--model` at the local path and drop `--load-format runai_streamer`.
- [ ] Check whether `HF_HUB_OFFLINE=1` is now safe, since the model is a local path. Set it only if the pod starts cleanly.
- [ ] Decide whether S3 staging stays as an optional path or goes. If it goes, remove the weights bucket and its Pod Identity role, and update `make down`.
- [ ] Write down the security change in DESIGN.md: access to the weights moves from a pod-scoped S3 role to the node's ECR pull permission.
- [ ] Compare cold start against v1 (GPU node ready → vLLM ready) and record it.
- **Done when:** vLLM serves from the image volume, the digest is pinned, and the cold-start comparison is in the lab log.

## Phase 4: chat and embedding on one GPU

- [ ] Choose a small, open, multilingual embedding model (owner's decision; candidates include Qwen3-Embedding-0.6B and bge-m3). Package it with Phase 3's script.
- [ ] Run it as a second vLLM Deployment in pooling (embedding) mode, exposing `/v1/embeddings`. Check the flag name for the vLLM version in use.
- [ ] Share the GPU through one MPS-configured claim (or time-slicing if Phase 0 said so). Give each pod a GPU memory limit, and set each vLLM's `--gpu-memory-utilization` inside it.
- [ ] Do the memory math in the primer: chat weights ~14.2 GiB plus its KV cache, embedding weights plus its working memory, all inside the A10G's ~22.5 GiB. Lower the chat model's `--max-model-len` if needed, and say so.
- [ ] Check startup order: vLLM measures free memory when it starts, so the second pod must still find room.
- [ ] A small client script that embeds a few French and English sentences and prints their cosine similarities.
- **Done when:** both models serve at the same time, `nvidia-smi` shows both processes on one GPU, and a pod that exceeds its cap fails without taking the other down.

## Phase 5: agentgateway and the Inference Extension

- [ ] Install the Gateway API CRDs, the Inference Extension CRDs and agentgateway with Helm. Get their images in through pull-through rules or the mirror script.
- [ ] Create an internal `Gateway` (ClusterIP Service, reached through the tunnel like everything else).
- [ ] Create two `InferencePool`s, `chat` and `embed`, each with an endpoint picker from llm-d. Check which EPP image and version match the CRDs.
- [ ] Route by the request's `model` field. Decide between llm-d's body-based routing and agentgateway's own model routing, and record why.
- [ ] Point Streamlit at the gateway instead of the vLLM Service.
- [ ] Add an API key at the gateway, so direct unauthenticated requests get a 401. Keys come from a Secret created out of band, never committed.
- [ ] Optional: a NetworkPolicy so only the gateway reaches the vLLM pods. Check that enforcement works on both node types before claiming it.
- **Done when:** `model=chat` and `model=embed` requests reach the right pool through one gateway, Streamlit works through it, and a request without a key is rejected.

## Phase 6 (optional): swap to Istio

- [ ] Install Istio with the Inference Extension enabled and change the `GatewayClass`. The `HTTPRoute` and `InferencePool` objects should not change; note anything that did.
- [ ] Compare the two in DESIGN.md: images to mirror, pods and memory used, features (mesh mTLS, ambient mode) and maturity of each one's extension support.
- **Done when:** the same routes work through Istio, and the comparison is written down.

## Phase 7: docs and merge

- [ ] Update README, DESIGN, the primer and the deck. The three-problems story still holds; add the GPU node group, image volumes and the gateway to it.
- [ ] New diagrams: hybrid compute, weights as images, gateway routing. Keep arrows off boxes and labels (`make diagrams`).
- [ ] Merge `v2` into `main`, and link the `v1` tag from the README for anyone who wants the simpler version.
- **Done when:** a fresh clone runs the full v2 flow from the README, and `make down` leaves a clean account.

## After v2

Ideas worth picking up once v2 works, each on its own branch:

- **A Helm chart for our own workloads,** replacing the `sed` templating in `scripts/deploy.sh`.
- **Observability:** Prometheus and Grafana (or Amazon Managed Prometheus through an endpoint), scraping vLLM, the gateway and GPU metrics, with a dashboard and a short "is it healthy" runbook.
- **Sizing:** an in-cluster load test that produces latency, time to first token and tokens per second by concurrency, for both models on the shared GPU.
- **TLS at the gateway,** with a private certificate source and a note on how clients trust it.
- **Break-it drills:** scripts that inject one fault each (KV cache too small, bad image digest, missing endpoint, `VLLM_PORT` collision, MPS cap exceeded) with a walkthrough for finding and fixing it.
- **The GPU Operator** instead of the self-installed DRA driver, to see what a full on-prem GPU stack involves.

## Decisions the owner still has to make

1. The embedding model.
2. MPS or time-slicing, after Phase 0.
3. Whether S3 staging stays as a fallback after Phase 3.
4. Body-based routing from llm-d or agentgateway's own model routing.
5. Whether to do the Istio comparison.
