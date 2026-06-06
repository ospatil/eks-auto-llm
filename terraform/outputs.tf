output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "bastion_instance_id" {
  description = "SSM target id. Use: aws ssm start-session --target <id>"
  value       = aws_instance.bastion.id
}

output "models_bucket" {
  description = "S3 bucket holding staged model weights."
  value       = aws_s3_bucket.models.bucket
}

output "ecr_streamlit_repo_url" {
  description = "Push the Streamlit image here."
  value       = aws_ecr_repository.streamlit.repository_url
}

# Full pull-through-cache image URI the cluster uses for vLLM. ECR auto-creates
# the backing repo (ecr-public/<upstream_path>) on first/pre-warm pull.
output "vllm_image_uri" {
  description = "vLLM image URI via the ECR Public pull-through cache."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix}/${var.vllm_upstream_path}:${var.vllm_image_tag}"
}

output "model_id" {
  value = var.model_id
}

output "namespace" {
  value = local.k8s_namespace
}

output "service_account" {
  value = local.k8s_service_account
}

# Convenience: command to open a shell on the bastion.
output "ssm_session_command" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.bastion.id}"
}

# Convenience: what to run ON the bastion to configure kubectl.
output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
