# Offline plan checks: no AWS credentials needed, nothing is created.
#   tofu -chdir=terraform test
# The AWS provider is mocked, so these check our own wiring (flags, names,
# counts), not what AWS would accept.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ca-central-1a", "ca-central-1b", "ca-central-1d"]
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:user/test"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/test"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/test"
    }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:ca-central-1:123456789012:cluster/test"
      endpoint              = "https://example.eks.amazonaws.com"
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.ca-central-1.amazonaws.com/id/TEST" }] }]
      certificate_authority = [{ data = "dGVzdA==" }]
    }
  }
  mock_resource "aws_launch_template" {
    defaults = {
      id  = "lt-0123456789abcdef0"
      arn = "arn:aws:ec2:ca-central-1:123456789012:launch-template/lt-0123456789abcdef0"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "ca-central-1"
      name   = "ca-central-1"
    }
  }
}

mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}

run "real_stack" {
  command = plan

  assert {
    condition     = module.eks.cluster_name == "eks-auto-llm"
    error_message = "real stack should keep the default cluster name"
  }
  assert {
    condition     = length(module.eks.eks_managed_node_groups) == 0
    error_message = "no node group unless enable_gpu_node_group"
  }
  assert {
    condition     = !contains(keys(aws_vpc_endpoint.interface), "ec2")
    error_message = "ec2 endpoint only with the GPU node group"
  }
  assert {
    condition     = aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix == "eks-auto-llm-pub"
    error_message = "ECR Public prefix should carry the project name"
  }
  assert {
    condition     = aws_ecr_pull_through_cache_rule.k8s.ecr_repository_prefix == "eks-auto-llm-k8s"
    error_message = "registry.k8s.io prefix should carry the project name"
  }
  assert {
    condition     = output.gpu_node_group == ""
    error_message = "gpu_node_group output should be empty without the node group"
  }
}

run "spike_stack" {
  command = plan

  variables {
    project               = "eks-auto-llm-spike"
    cluster_name          = "eks-auto-llm-spike"
    enable_gpu_node_group = true
  }

  assert {
    condition     = module.eks.cluster_name == "eks-auto-llm-spike"
    error_message = "spike cluster name"
  }
  assert {
    condition     = contains(keys(module.eks.eks_managed_node_groups), "gpu")
    error_message = "spike stack should plan the gpu node group"
  }
  assert {
    condition     = contains(keys(aws_vpc_endpoint.interface), "ec2")
    error_message = "spike stack should plan the ec2 endpoint"
  }
  assert {
    condition     = length(aws_vpc_endpoint.interface) == 9
    error_message = "eight v1 endpoints plus ec2"
  }
  assert {
    condition     = aws_ecr_pull_through_cache_rule.k8s.ecr_repository_prefix == "eks-auto-llm-spike-k8s"
    error_message = "spike prefixes must differ from the real stack's"
  }
  assert {
    condition     = length(aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix) <= 30 && length(aws_ecr_pull_through_cache_rule.k8s.ecr_repository_prefix) <= 30
    error_message = "ECR pull-through prefixes are limited to 30 characters"
  }
  assert {
    condition     = output.gpu_node_group == "gpu"
    error_message = "gpu_node_group output feeds make gpu-nodes"
  }
  assert {
    condition     = anytrue([for t in module.eks.eks_managed_node_groups["gpu"].node_group_taints : t.key == "nvidia.com/gpu" && t.effect == "NO_SCHEDULE"])
    error_message = "GPU node group must carry the nvidia.com/gpu NoSchedule taint"
  }
  assert {
    condition     = module.eks.eks_managed_node_groups["gpu"].node_group_labels["eks-auto-llm/gpu"] == "node-group"
    error_message = "spike manifests and DRA values select the node group by this label"
  }
  assert {
    condition     = aws_s3_bucket.models.bucket_prefix == "eks-auto-llm-spike-models-"
    error_message = "spike bucket should carry the spike project name"
  }
}

run "spike_stack_al2023_fallback" {
  command = plan

  variables {
    project               = "eks-auto-llm-spike"
    cluster_name          = "eks-auto-llm-spike"
    enable_gpu_node_group = true
    gpu_ami_type          = "AL2023_x86_64_NVIDIA"
  }

  assert {
    condition     = contains(keys(module.eks.eks_managed_node_groups), "gpu")
    error_message = "the AL2023 fallback should still plan the gpu node group"
  }
}
