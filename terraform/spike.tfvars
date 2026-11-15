# Phase 0 spike stack. Used by `make <target> SPIKE=1`, which also selects the
# `spike` workspace, so this stack has its own state and can exist next to the
# real one. Its own project name keeps IAM roles, ECR repos and pull-through
# prefixes apart. No account-specific values here; the repo is public.
project               = "eks-auto-llm-spike"
cluster_name          = "eks-auto-llm-spike"
enable_gpu_node_group = true
