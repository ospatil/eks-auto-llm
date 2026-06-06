# EKS Pod Identity: associate an IAM role with the `model-storage-sa` service
# account in the `llm` namespace. Pods using that SA automatically receive
# temporary credentials (the Pod Identity Agent is built into Auto Mode).
#
# Scope: READ-ONLY on the single weights bucket. Weights are staged out-of-band
# from your laptop (scripts/stage-model.sh), so the cluster only ever reads -
# it never writes to S3 and never contacts HuggingFace.

locals {
  k8s_namespace       = "llm"
  k8s_service_account = "model-storage-sa"
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    sid     = "AllowEksAuthToAssumeRoleForPodIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "model_storage" {
  name               = "${var.project}-model-storage"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "model_storage_s3" {
  statement {
    sid       = "ListWeightsBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.models.arn]
  }
  statement {
    sid       = "ReadWeights"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.models.arn}/*"]
  }
}

resource "aws_iam_role_policy" "model_storage_s3" {
  name   = "s3-weights-access"
  role   = aws_iam_role.model_storage.id
  policy = data.aws_iam_policy_document.model_storage_s3.json
}

resource "aws_eks_pod_identity_association" "model_storage" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.k8s_namespace
  service_account = local.k8s_service_account
  role_arn        = aws_iam_role.model_storage.arn
}
