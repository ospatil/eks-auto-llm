# EKS Auto Mode cluster with a PRIVATE-ONLY API endpoint.
#
# Auto Mode manages: Karpenter node provisioning, NVIDIA GPU drivers + device
# plugin, the EBS CSI / storage, the load balancer controller, CoreDNS, and the
# EKS Pod Identity Agent. We do NOT install any of those add-ons ourselves.
#
# v21 input names differ from v20 (name/kubernetes_version/endpoint_*). Pinned
# to ~> 21.0 which added these and native compute_config (Auto Mode) support.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # ---- Auto Mode ----
  # Enabling compute_config with the built-in node pools turns on Auto Mode and
  # makes the module create the Auto Mode cluster + node IAM roles with the
  # correct minimal managed policies.
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  # ---- Private endpoint ----
  endpoint_private_access = true
  endpoint_public_access  = false

  # API authentication mode = access entries (Auto Mode default; no aws-auth CM).
  # Grant the identity running `apply` cluster-admin so it can be mapped, and so
  # the bastion access entry (see bastion.tf) can be added.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  tags = {
    Project = var.project
  }
}

# Allow the bastion's security group to reach the cluster API on 443. The module
# exposes the cluster (control-plane) security group id; we add an ingress rule
# from the bastion SG so kubectl/helm work from the bastion.
resource "aws_security_group_rule" "cluster_api_from_bastion" {
  description              = "Allow bastion to reach the private EKS API server"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = aws_security_group.bastion.id
}
