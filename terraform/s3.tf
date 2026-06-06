# Bucket holding the model weights staged from HuggingFace. vLLM streams from
# here at runtime over the S3 gateway endpoint (no NAT, stays on AWS network).
# force_destroy=true so the stack tears down completely (no orphaned bucket).

resource "aws_s3_bucket" "models" {
  bucket_prefix = "${var.project}-models-"
  force_destroy = var.bucket_force_destroy
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
