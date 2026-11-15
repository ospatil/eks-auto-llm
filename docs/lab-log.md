# Lab log

What was built, what broke, timings and cost, newest entry last. See [v2-plan.md](./v2-plan.md) for the plan this follows. No account IDs, profile names or hostnames here: the repo is public.

## 2026-11-15: Phase 0 prep (no cloud)

Built locally, nothing applied:

- Terraform for the spike cluster, which is also the Phase 1 Terraform behind a flag: Kubernetes 1.37, an optional managed `gpu` node group (Bottlerocket NVIDIA, `g5.xlarge`, 0 to 1), the `vpc-cni`, `kube-proxy` and `eks-pod-identity-agent` add-ons, and an `ec2` interface endpoint for the CNI. All of it switches on with `enable_gpu_node_group`.
- The spike runs as its own stack: `make up SPIKE=1` uses the `spike` workspace and [`terraform/spike.tfvars`](../terraform/spike.tfvars), with its own project name, so it can exist next to the real stack. Its kubeconfig is `kubeconfig-spike` and its tunnel listens on `:8444`.
- ECR pull-through prefixes are now named after the project (`<project>-pub`, `<project>-k8s`), and `make down` deletes every ECR repository the project owns.
- A pull-through rule for `registry.k8s.io`, where the NVIDIA DRA driver image lives, so it needs no mirroring.
- `scripts/mirror-image.sh` for images whose registry ECR can't cache.
- Spike manifests in [`spikes/`](../spikes/).

Facts checked today, on top of those in the plan:

- **Bottlerocket's device plugin switch** is `settings.kubelet-device-plugins.nvidia.enabled = false`. It exists from Bottlerocket 1.63.0; older versions can't turn the plugin off. ([EKS docs](https://docs.aws.amazon.com/eks/latest/userguide/device-management-nvidia-dra-device-plugin.html), [Bottlerocket settings](https://bottlerocket.dev/en/os/1.37.x/api/settings/kubelet-device-plugins/))
- **NVIDIA DRA driver chart** is `oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu`, latest 0.5.1. It uses one image, `registry.k8s.io/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.5.1`. The EKS docs show 0.4.1 with `gpuResourcesEnabledOverride=true` and `resources.computeDomains.enabled=false`.
- **MPS** is the `featureGates.MPSSupport` gate (alpha, off by default). It can't be combined with `DynamicMIG`. Time-slicing settings are behind `featureGates.TimeSlicingSettings`. ([MPS guide](https://dra-driver-nvidia-gpu.sigs.k8s.io/docs/guides/mps/))
- **The kubelet plugin's default node affinity** needs NFD or GPU Operator labels, which our nodes don't have. The spike values file pins it to the node group's label instead.

Open questions the spikes should answer:

- Do the EKS add-ons stay off Auto Mode nodes, or do they need an affinity?
- Do pods on node-group nodes resolve DNS without the `coredns` add-on?
- Does the Auto Mode Bottlerocket variant run containerd 2.2 (needed for image volume `subPath`)?
- Is the node group's Bottlerocket release 1.63.0 or later?

## Spike results

| Spike | Result | Go / no-go | Notes |
|---|---|---|---|
| Hybrid cluster | not run | | |
| Image volumes | not run | | |
| MPS on the A10G | not run | | |

### Timings

| What | Time |
|---|---|
| `make up SPIKE=1` | |
| GPU node group 0 → node Ready | |
| ~15 GB weights image pull | |

### Cost

| Item | Hours | Cost |
|---|---|---|
| | | |
