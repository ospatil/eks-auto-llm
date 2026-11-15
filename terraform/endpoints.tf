# VPC endpoints let a fully-private cluster reach AWS services without going
# over the internet/NAT:
#   - ssm/ssmmessages/ec2messages : SSM Session Manager (bastion access)
#   - sts                         : regional STS (SDK token exchange)
#   - ecr.api + ecr.dkr + S3 (gw) : pull container images privately
#   - eks-auth                    : MANDATORY for Pod Identity to issue creds privately
#   - eks                         : EKS AWS API (control-plane mgmt, optional but tidy)
#   - s3 (gateway)                : ECR layers AND vLLM model streaming from S3 (no NAT)
#   - ec2 (GPU node group only)   : the VPC CNI calls the EC2 API to manage ENIs and IPs

locals {
  interface_endpoints = concat([
    "ssm",
    "ssmmessages",
    "ec2messages",
    "sts",
    "ecr.api",
    "ecr.dkr",
    "eks-auth",
    "eks",
  ], var.enable_gpu_node_group ? ["ec2"] : [])
}

# Security group allowing HTTPS from inside the VPC to the interface endpoints.
resource "aws_security_group" "vpce" {
  name_prefix = "${var.project}-vpce-"
  description = "Allow HTTPS from within the VPC to interface VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from within VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-vpce" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "${var.project}-vpce-${each.value}" }
}

# S3 gateway endpoint - free, attaches to route tables. Used for ECR image
# layers and vLLM streaming model weights from S3 without traversing NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "${var.project}-vpce-s3" }
}
