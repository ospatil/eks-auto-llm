data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Private /20 subnets per AZ. No public subnets: this is a fully private,
  # air-gapped data plane (no NAT, no Internet Gateway). All AWS access is via
  # VPC endpoints (see endpoints.tf).
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.project}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = [] # none - no internet egress at all

  # No NAT and (implicitly) no Internet Gateway. The cluster reaches AWS
  # services only through VPC endpoints; container images are pulled from ECR.
  enable_nat_gateway = false

  # Required for the EKS-managed private hosted zone to resolve the private API.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS Auto Mode uses this tag to place INTERNAL load balancers. We only use
  # ClusterIP services here, but the tag is harmless and correct for private
  # subnets. (No public elb tag - there are no public subnets.)
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
