# Phase 0 spikes

Three throwaway experiments from [the v2 plan](../docs/v2-plan.md#phase-0-spikes), run on a separate spike stack before the real stack changes. Each ends in a go or no-go in [the lab log](../docs/lab-log.md), with timings. This folder is removed before `v2` merges.

The spike stack is the real Terraform with [`spike.tfvars`](../terraform/spike.tfvars): its own workspace and project name, the GPU node group switched on. Add `SPIKE=1` to every `make` target.

## Local checks first (free)

Before spending anything, run what can run without AWS or a GPU:

```bash
make test                 # offline Terraform plan tests (mocked AWS)
spikes/local/up.sh        # kind 1.37 + local registry, shaped like the spike cluster
spikes/local/verify.sh    # the scripts and manifests against it; PASS/FAIL per check
spikes/local/down.sh
```

`verify.sh` proves the image scripts, that a 1.37 API server accepts every manifest, image volume mounts (whole, `subPath`, read-only) on containerd 2.x, pod placement by node type, and the DRA chart's placement and image path. It can't prove anything about Auto Mode, Bottlerocket, endpoints, ECR, pull times or the GPU.

`push-image.sh` needs `docker buildx`. If your default builder is a `docker-container` one, pushing to ECR still works, but the 15 GB build context gets copied into the builder container first; `BUILDX_BUILDER=<your docker context>` uses the daemon directly.

## Before the session

Free, and best done the day before so the stack isn't running while it downloads:

```bash
hf download Qwen/Qwen2.5-7B-Instruct   --local-dir <weights dir>    # ~15 GB, spike 2
hf download Qwen/Qwen2.5-0.5B-Instruct --local-dir <small dir>      # spike 3
colima start                                                        # docker for push-image.sh
```

## One-sitting order

The stack costs about $0.35 an hour, and $1.45 with the GPU node (see the lab log). To keep the GPU hours down:

1. `make preflight`, `make up SPIKE=1`, the prewarm steps under "Bring it up". GPU at 0.
2. Push the images while the GPU is still at 0: `hello`, `qwen2.5-7b-instruct` and `qwen2.5-0.5b-instruct`. The 15 GB push is the slow part and depends on your upload speed.
3. `make gpu-nodes N=1 SPIKE=1`, then spike 1, spike 2 (the pods only, the images are already pushed) and spike 3.
4. `make gpu-nodes N=0 SPIKE=1` as soon as spike 3 is done. Write up the results with the GPU off.
5. `make down SPIKE=1` the same day, and check that nothing is left.

If the AL2023 fallback is needed in spike 3, the `make up SPIKE=1` that switches it replaces the GPU node; budget another 15–20 minutes of GPU time.

## Bring it up

```bash
make preflight
make up SPIKE=1                 # time it
make prewarm SPIKE=1            # the vLLM image, used by spike 3
make tunnel SPIKE=1             # terminal 1: tunnel on :8444
export KUBECONFIG=$PWD/kubeconfig-spike TF_WORKSPACE=spike   # terminal 2
kubectl apply -f spikes/namespace.yaml
```

`TF_WORKSPACE=spike` makes plain `tofu` commands in that terminal read the spike stack; `spikes/*.sh` default to it anyway. Don't run `make` for the real stack from that terminal.

Prewarm busybox and the DRA driver image too, so no node pulls through the cache first:

```bash
REG=$(tofu -chdir=terraform output -raw ecr_registry)
scripts/prewarm-image.sh \
  "$REG/eks-auto-llm-spike-pub/docker/library/busybox:1.37" \
  "$(tofu -chdir=terraform output -raw k8s_cache_prefix)/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.5.1"
```

## Spike 1: hybrid cluster

Does a managed node group join a private Auto Mode cluster with no NAT, and do the add-ons leave the Auto Mode nodes alone?

```bash
make gpu-nodes N=1 SPIKE=1      # time until the node is Ready
kubectl get nodes -L eks.amazonaws.com/compute-type,eks-auto-llm/gpu -o wide
kubectl -n kube-system get ds,pods -o wide        # where did aws-node, kube-proxy, eks-pod-identity-agent land?
spikes/render.sh spikes/hybrid/dns-check.yaml | kubectl apply -f -
kubectl -n spike logs net-auto; kubectl -n spike logs net-nodegroup
```

Record:

- [ ] Time from `gpu-nodes N=1` to node Ready, and any join errors (`aws eks describe-nodegroup ... --query nodegroup.health`).
- [ ] Add-on pods run on the node-group node and not on Auto Mode nodes. If they land on Auto Mode nodes, note what affinity they need.
- [ ] `net-nodegroup` resolves cluster and AWS names and reaches the API. If DNS fails, try the `coredns` add-on.
- [ ] The node's Bottlerocket version (`kubectl get node -o wide`, OS image) is 1.63.0 or later, and `kubectl describe node` shows no `nvidia.com/gpu` capacity (the bundled device plugin is off).
- [ ] containerd version on each node type (`CONTAINER-RUNTIME` column).

## Spike 2: image volumes

```bash
spikes/push-image.sh hello spikes/image-volume/hello      # prints "Pin as: ...@sha256:..."
export HELLO_IMAGE=<that reference>
spikes/render.sh spikes/image-volume/pods.yaml | kubectl apply -f -
kubectl -n spike logs imgvol-auto; kubectl -n spike logs imgvol-nodegroup
```

Then the real size, with the weights already on your laptop from `make stage` (or `hf download Qwen/Qwen2.5-7B-Instruct --local-dir ...`):

```bash
spikes/push-image.sh qwen2.5-7b-instruct <weights dir>    # time the push
export WEIGHTS_IMAGE=<that reference>
spikes/render.sh spikes/image-volume/weights-pull.yaml | kubectl apply -f -
kubectl -n spike get events --field-selector involvedObject.name=weights-pull -w
```

Record:

- [ ] Both pods mount the image whole and with `subPath`. If `subPath` fails on one node type, note its containerd version.
- [ ] Push time and image size. Whether ECR accepted each shard as one layer.
- [ ] Pull time on a fresh node (the `Pulled` event gives it), and again after deleting and re-creating the pod.

## Spike 3: MPS on the A10G

Install the DRA driver on the GPU node only:

```bash
helm install dra-driver oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu \
  --version 0.5.1 -n nvidia-dra --create-namespace \
  -f <(spikes/render.sh spikes/mps/dra-values.yaml)
kubectl -n nvidia-dra get pods -o wide
kubectl get deviceclass; kubectl get resourceslices -o wide   # the A10G should be listed
```

Two capped pods on one MPS claim:

```bash
kubectl apply -f spikes/mps/claim-mps.yaml
spikes/render.sh spikes/mps/memory-test.yaml | kubectl apply -f -
kubectl -n spike logs mps-big; kubectl -n spike logs mps-small
kubectl -n spike exec mps-big -- nvidia-smi
```

Then two vLLM servers. Push a small model (`hf download Qwen/Qwen2.5-0.5B-Instruct --local-dir ...`, then `spikes/push-image.sh qwen2.5-0.5b-instruct <dir>`) and set `SMALL_IMAGE`:

```bash
kubectl -n spike delete pod mps-big mps-small
spikes/render.sh spikes/mps/vllm-pair.yaml | kubectl apply -f -   # or one pod at a time, see the file
kubectl -n spike get pods -l spike=vllm-pair -w
kubectl -n spike exec vllm-a -- nvidia-smi
```

If the driver's init container keeps logging `nvidia-smi: not found, libnvidia-ml.so.1: not found`, it can't find Bottlerocket's NVIDIA driver under `nvidiaDriverRoot: /`. (AWS's docs disagree on whether the DRA driver supports Bottlerocket at all.) Look for the files on the node:

```bash
kubectl debug node/<gpu node> -it --image="$REG/eks-auto-llm-spike-pub/docker/library/busybox:1.37" -- \
  sh -c 'find /host -name libnvidia-ml.so.1 -o -name nvidia-smi 2>/dev/null'
```

If they sit under one root, set `nvidiaDriverRoot` to it and upgrade the release. If not, switch the node group to AL2023, which has no bundled device plugin: add `gpu_ami_type = "AL2023_x86_64_NVIDIA"` to `spike.tfvars`, `make up SPIKE=1`, and record the switch.

If MPS doesn't work, delete the claim and pods, apply `claim-timeslicing.yaml`, and repeat.

Record:

- [ ] The driver's pods run, and the GPU shows up in a `ResourceSlice`. If not, where Bottlerocket keeps `libnvidia-ml.so.1`, and whether AL2023 was needed.
- [ ] How much each memory-test pod allocated. Did `CUDA_MPS_PINNED_DEVICE_MEM_LIMIT` lower the cap, raise it, or neither? This decides whether chat and embedding can have different caps on one claim.
- [ ] `nvidia-smi` shows both processes on one GPU.
- [ ] Both vLLM servers become Ready, and what memory each reports in its startup log.
- [ ] If falling back to time-slicing: what was lost (no memory cap, so a runaway pod can starve the other).

## Tear down

```bash
make down SPIKE=1
```

This deletes the stack and every ECR repo whose name starts with `eks-auto-llm-spike`. Check that no instances or node groups are left, and record the total hours and cost in the lab log.
