data "aws_caller_identity" "current" {}

# Private ECR repo for the Streamlit chat app image. Auto Mode nodes pull from
# here over the ecr.api/ecr.dkr interface endpoints + S3 gateway endpoint.
# force_delete=true to allow `destroy` to remove the repo with images present.

resource "aws_ecr_repository" "streamlit" {
  name                 = "${var.project}/streamlit-chat"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep only the most recent few images to avoid unbounded storage on a test repo.
resource "aws_ecr_lifecycle_policy" "streamlit" {
  repository = aws_ecr_repository.streamlit.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ---- vLLM image delivery: ECR pull-through cache from ECR Public ----
#
# The cluster has no internet egress, so it can't pull from Docker Hub (where
# the upstream vllm/vllm-openai lives). Instead we use an ECR PULL-THROUGH CACHE
# rule against ECR Public (public.ecr.aws), whose vLLM Deep Learning Container
# needs NO credentials. How it stays air-gapped:
#   - For unauthenticated upstreams, ECR fetches the image SERVER-SIDE from AWS
#     IPs - the node/VPC never contacts the internet.
#   - We additionally PRE-WARM (scripts/prewarm-image.sh) from your laptop so the
#     cache repo + image exist before any node pulls. Nodes then do plain cached
#     pulls over the ecr.api/ecr.dkr + S3 endpoints with only PullOnly perms.
#
# Cached images land in an auto-created repo named "<prefix>/<upstream-path>".
# With the "<project>-pub" prefix and the DLC path, the node pull URI is:
#   <acct>.dkr.ecr.<region>.amazonaws.com/<project>-pub/deep-learning-containers/vllm:<tag>
# Prefixes are unique per region, so they carry the project name: that lets the
# spike stack exist next to the real one, and lets destroy.sh find every repo
# this project created.
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "${var.project}-pub"
  upstream_registry_url = "public.ecr.aws"
}

# Same idea for registry.k8s.io, which hosts the NVIDIA DRA driver image (and
# later the Gateway API Inference Extension images). Also unauthenticated.
resource "aws_ecr_pull_through_cache_rule" "k8s" {
  ecr_repository_prefix = "${var.project}-k8s"
  upstream_registry_url = "registry.k8s.io"
}
