#!/usr/bin/env bash
# Fail-fast checks before spinning up the cluster: tooling, AWS creds, region,
# and (critically) GPU vCPU service quota in the target region.
set -euo pipefail

REGION="${REGION:-ca-central-1}"
# "Running On-Demand G and VT instances" quota. A g5.xlarge needs 4 vCPUs.
GPU_QUOTA_CODE="L-DB2E81BA"
GPU_VCPUS_NEEDED=4

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

fail=0
need() {
  if command -v "$1" >/dev/null 2>&1; then
    green "  ✓ $1 found"
  else
    red "  ✗ $1 NOT found - $2"
    fail=1
  fi
}

echo "== Tooling =="
# Accept either OpenTofu or Terraform.
if command -v tofu >/dev/null 2>&1; then
  green "  ✓ tofu found"
elif command -v terraform >/dev/null 2>&1; then
  yellow "  ~ tofu not found; will use terraform instead"
else
  red "  ✗ neither tofu nor terraform found - install OpenTofu (brew install opentofu)"
  fail=1
fi
need aws "install AWS CLI v2"
need kubectl "install kubectl"
need session-manager-plugin "install the AWS SSM Session Manager plugin"
need helm "install Helm (brew install helm) - v2 installs the NVIDIA DRA driver and the gateway with it"
if command -v crane >/dev/null 2>&1 || command -v skopeo >/dev/null 2>&1; then
  green "  ✓ crane or skopeo found"
else
  yellow "  ~ neither crane nor skopeo found - only needed by scripts/mirror-image.sh (brew install crane)"
fi

echo "== AWS credentials =="
if ident=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null); then
  green "  ✓ authenticated as: ${ident}"
else
  red "  ✗ no AWS credentials - run your login (e.g. aws sso login) first"
  fail=1
fi

echo "== Region =="
green "  → using REGION=${REGION}"
if [ "${AWS_REGION:-}" != "" ] && [ "${AWS_REGION}" != "${REGION}" ]; then
  yellow "  ~ note: AWS_REGION env is '${AWS_REGION}', but this project forces '${REGION}'"
fi

echo "== GPU service quota (${REGION}) =="
if [ "$fail" -eq 0 ]; then
  quota=$(aws service-quotas get-service-quota \
    --service-code ec2 --quota-code "${GPU_QUOTA_CODE}" \
    --region "${REGION}" --query 'Quota.Value' --output text 2>/dev/null || echo "ERR")
  if [ "$quota" = "ERR" ]; then
    yellow "  ~ couldn't read the quota (permissions?). Verify manually:"
    yellow "    aws service-quotas get-service-quota --service-code ec2 --quota-code ${GPU_QUOTA_CODE} --region ${REGION}"
  else
    quota_int=${quota%.*}
    if [ "${quota_int:-0}" -ge "$GPU_VCPUS_NEEDED" ]; then
      green "  ✓ G/VT on-demand vCPU quota = ${quota_int} (need ≥ ${GPU_VCPUS_NEEDED})"
    else
      red "  ✗ G/VT on-demand vCPU quota = ${quota_int}; need ≥ ${GPU_VCPUS_NEEDED} for a g5.xlarge."
      red "    Request an increase (can take up to ~24h to approve):"
      red "    aws service-quotas request-service-quota-increase \\"
      red "      --service-code ec2 --quota-code ${GPU_QUOTA_CODE} \\"
      red "      --desired-value ${GPU_VCPUS_NEEDED} --region ${REGION}"
      fail=1
    fi
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  green "Preflight passed."
else
  red "Preflight FAILED - resolve the items above before 'make up'."
  exit 1
fi
