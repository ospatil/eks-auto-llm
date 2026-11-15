#!/usr/bin/env bash
# Check as much of the Phase 0 spikes as runs without AWS or a GPU, on the
# kind cluster from up.sh. Prints PASS/FAIL per check and exits non-zero on
# any failure.
#
# What this proves: the scripts work, the manifests are accepted by a 1.37 API
# server, image volumes mount whole and with subPath on containerd 2.x, pods
# land on the right node "type", and the DRA driver chart schedules only on the
# node-group node. What it can't prove: anything about Auto Mode, Bottlerocket,
# VPC endpoints, ECR, pull times, or the GPU (MPS caps, vLLM).
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
REG_PORT="${REG_PORT:-5001}"
export KUBECONFIG="${KUBECONFIG_FILE:-$PWD/kubeconfig-local}"
export REGISTRY="localhost:${REG_PORT}" PROJECT="local" PLATFORM="linux/arm64"
# The context's built-in "docker" builder pushes from the Docker daemon, which
# reaches localhost:<port>; a docker-container builder would not.
export BUILDX_BUILDER="${BUILDX_BUILDER:-$(docker context show)}"
export VLLM_IMAGE="${REGISTRY}/${PROJECT}-pub/docker/library/busybox:1.37"   # stand-in; GPU pods never start here
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@" >"$WORK/out" 2>&1; then pass "$name"; else fail "$name"; sed 's/^/     /' "$WORK/out" | tail -15; fi; }
render() { spikes/render.sh "$1"; }
wait_running() { kubectl -n spike wait --for=jsonpath='{.status.phase}'=Running "pod/$1" --timeout=180s; }
node_of() { kubectl -n spike get pod "$1" -o jsonpath='{.spec.nodeName}'; }
label_of() { kubectl get node "$1" -o jsonpath="{.metadata.labels.$2}"; }

echo "== Cluster"
check "nodes Ready" kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl apply -f spikes/namespace.yaml >/dev/null

echo "== Images"
# Stand-in for the ECR Public pull-through cache: same path layout.
check "busybox into <project>-pub/docker/library (pull-through layout)" \
  crane copy docker.io/library/busybox:1.37 "${REGISTRY}/${PROJECT}-pub/docker/library/busybox:1.37"
check "DRA driver image into <project>-k8s/ (pull-through layout)" \
  crane copy registry.k8s.io/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.5.1 \
    "${REGISTRY}/${PROJECT}-k8s/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.5.1"

mirror_digest_matches() {
  scripts/mirror-image.sh docker.io/library/busybox:1.37 || return 1
  up="$(crane digest docker.io/library/busybox:1.37)"
  mine="$(crane digest "${REGISTRY}/${PROJECT}/mirror/library/busybox:1.37")"
  echo "upstream=${up} mirror=${mine}"
  [ "$up" = "$mine" ]
}
check "mirror-image.sh keeps the upstream digest" mirror_digest_matches

push_hello() {
  spikes/push-image.sh hello spikes/image-volume/hello | tee "$WORK/hello.log" || return 1
  grep -q '^Pin as: .*@sha256:' "$WORK/hello.log"
}
check "push-image.sh hello prints a digest-pinned ref" push_hello
HELLO_IMAGE="$(sed -n 's/^Pin as: //p' "$WORK/hello.log")"
export HELLO_IMAGE

# A fake "model": four shard-like files and a config, to check one layer per file.
mkdir -p "$WORK/model"
for i in 1 2 3 4; do head -c 2097152 /dev/urandom > "$WORK/model/model-0000${i}-of-00004.safetensors"; done
echo '{"model_type":"fake"}' > "$WORK/model/config.json"
push_weights() {
  spikes/push-image.sh fake-weights "$WORK/model" | tee "$WORK/weights.log" || return 1
  ref="$(sed -n 's/^Pin as: //p' "$WORK/weights.log")"
  layers="$(crane manifest "$ref" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["layers"]))')"
  echo "layers=${layers}"
  [ "$layers" -eq 5 ]
}
check "push-image.sh makes one layer per top-level file (5)" push_weights
WEIGHTS_IMAGE="$(sed -n 's/^Pin as: //p' "$WORK/weights.log")"
export WEIGHTS_IMAGE SMALL_IMAGE="$WEIGHTS_IMAGE"
if [ "$fails" -gt 0 ]; then
  printf '\033[31m%d image check(s) failed; the rest depend on them, stopping.\033[0m\n' "$fails"
  exit 1
fi

echo "== Every spike manifest passes server-side validation"
for f in spikes/hybrid/dns-check.yaml spikes/image-volume/pods.yaml spikes/image-volume/weights-pull.yaml \
         spikes/mps/claim-mps.yaml spikes/mps/memory-test.yaml spikes/mps/vllm-pair.yaml; do
  dry_run() { render "$1" | kubectl apply --dry-run=server -f -; }
  check "$f" dry_run "$f"
done
leftover() {
  out="$(for f in spikes/*/*.yaml; do render "$f"; done | grep -o '__[A-Z0-9_]*__' | sort -u)"
  [ -z "$out" ] || { echo "unfilled: $out"; return 1; }
}
check "render.sh fills every placeholder" leftover
check "spikes/mps/claim-timeslicing.yaml" sh -c 'kubectl apply --dry-run=server -f spikes/mps/claim-timeslicing.yaml'

echo "== Spike 1 stand-in: pods land on the right node type and resolve DNS"
render spikes/hybrid/dns-check.yaml | kubectl apply -f - >/dev/null
check "net-auto Running" wait_running net-auto
check "net-nodegroup Running (tolerates the GPU taint)" wait_running net-nodegroup
check "net-auto is on the 'auto' node" sh -c "[ \"\$(kubectl get node $(node_of net-auto) -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/compute-type}')\" = auto ]"
check "net-nodegroup is on the node-group node" sh -c "[ \"\$(kubectl get node $(node_of net-nodegroup) -o jsonpath='{.metadata.labels.eks-auto-llm/gpu}')\" = node-group ]"
sleep 5
check "net-nodegroup resolves cluster DNS" sh -c "kubectl -n spike logs net-nodegroup | grep -A3 'kubernetes.default.svc.cluster.local' | grep -q 'Address'"

echo "== Spike 2 stand-in: image volumes, whole and subPath, on both node types"
render spikes/image-volume/pods.yaml | kubectl apply -f - >/dev/null
for p in imgvol-auto imgvol-nodegroup; do
  check "$p Running" wait_running "$p"
  sleep 2
  check "$p reads /data/hello.txt (whole image)" sh -c "kubectl -n spike logs $p | grep -q 'Hello from an image volume.'"
  check "$p reads /sub/sub.txt (subPath)" sh -c "kubectl -n spike logs $p | grep -q 'Hello from a subPath mount.'"
done
check "image volume is read-only" sh -c "kubectl -n spike exec imgvol-auto -- touch /data/x 2>&1 | grep -q 'Read-only file system'"
render spikes/image-volume/weights-pull.yaml | kubectl apply -f - >/dev/null
check "weights-pull Running" wait_running weights-pull
sleep 2
check "weights-pull sees the shards" sh -c "kubectl -n spike logs weights-pull | grep -q 'model-00004-of-00004.safetensors'"

echo "== Spike 3 stand-in: DRA driver chart placement (no GPU, so it can't go Ready)"
helm_install() {
  helm upgrade --install dra-driver oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu \
    --version 0.5.1 -n nvidia-dra --create-namespace -f <(render spikes/mps/dra-values.yaml)
}
check "helm install with spike values" helm_install
check "DeviceClass gpu.nvidia.com exists" kubectl get deviceclass gpu.nvidia.com
sleep 10
placement() {
  nodes="$(kubectl -n nvidia-dra get pods -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)"
  echo "plugin pods on: ${nodes:-<none>}"
  [ -n "$nodes" ] || return 1
  for n in $nodes; do [ "$(label_of "$n" 'eks-auto-llm/gpu')" = node-group ] || return 1; done
}
check "kubelet plugin runs only on the node-group node" placement
pulled_from_cache() {
  kubectl -n nvidia-dra get pods -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u | tee /dev/stderr \
    | grep -qx "${REGISTRY}/${PROJECT}-k8s/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.5.1"
}
check "driver image comes from the <project>-k8s prefix" pulled_from_cache
kubectl apply -f spikes/mps/claim-mps.yaml >/dev/null
check "MPS ResourceClaim accepted (stays unallocated: no GPU)" kubectl -n spike get resourceclaim shared-gpu

echo
kubectl -n nvidia-dra get pods -o wide 2>/dev/null | sed 's/^/  /'
echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32mAll local checks passed.\033[0m\n'
else
  printf '\033[31m%d check(s) failed.\033[0m\n' "$fails"
  exit 1
fi
