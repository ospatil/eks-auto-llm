# Provider + tooling pins.
#
# This config is written to work with EITHER OpenTofu (`tofu`) or Terraform
# (`terraform`) - the HCL is identical. The Makefile auto-detects which binary
# is installed. Only the AWS provider is declared here on purpose: with a
# PRIVATE EKS endpoint the kubernetes/helm providers cannot reach the cluster
# from outside the VPC, so all in-cluster resources are applied separately from
# the bastion (see README). Keeping this state AWS-only also makes `destroy`
# reliable.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.42"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "opentofu"
      Purpose   = "eks-auto-mode-vllm-llm-test"
    }
  }
}
