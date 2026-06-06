variable "region" {
  description = "AWS region. ca-central-1 has g5 (A10G) capacity."
  type        = string
  default     = "ca-central-1"
}

variable "project" {
  description = "Short name used to prefix/namespace resources."
  type        = string
  default     = "eks-auto-llm"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "eks-auto-llm"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes control-plane version."
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "CIDR for the cluster VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones (EKS requires >= 2)."
  type        = number
  default     = 2
}

variable "bastion_instance_type" {
  description = "Instance type for the SSM bastion. t3.small is plenty for kubectl/helm."
  type        = string
  default     = "t3.small"
}

variable "model_id" {
  description = <<-EOT
    HuggingFace model repo id to stage into S3 and serve. Default is the open
    Apache-2.0 Qwen model which needs NO HuggingFace token. To use gated Llama
    (meta-llama/Llama-3.1-8B-Instruct) set this and provide an HF token to the
    staging Job (see README).
  EOT
  type        = string
  default     = "Qwen/Qwen2.5-7B-Instruct"
}

# vLLM image served via the ECR Public pull-through cache (AWS vLLM DLC).
# The upstream repo path under public.ecr.aws and the tag to serve. DLC tags are
# long and rotate; verify a current one in the ECR Public Gallery before deploy:
#   https://gallery.ecr.aws/deep-learning-containers/vllm
variable "vllm_upstream_path" {
  description = "Upstream repo path under public.ecr.aws for the vLLM DLC."
  type        = string
  default     = "deep-learning-containers/vllm"
}

variable "vllm_image_tag" {
  description = "vLLM DLC image tag to pull through the cache and serve. VERIFY current."
  type        = string
  default     = "0.22.0-gpu-py312-cu130-ubuntu22.04-ec2-v1.1"
}

variable "bucket_force_destroy" {
  description = "Allow `destroy` to delete the weights bucket even if non-empty, so teardown is complete. Set false to retain staged weights across destroys."
  type        = bool
  default     = true
}
