# EKS Auto Mode cluster with a PRIVATE-ONLY API endpoint.
#
# Auto Mode manages: Karpenter node provisioning, NVIDIA GPU drivers + device
# plugin, the EBS CSI / storage, the load balancer controller, CoreDNS, and the
# EKS Pod Identity Agent. We do NOT install any of those add-ons ourselves -
# except for the optional GPU node group below, whose nodes Auto Mode doesn't
# manage.
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

  # ---- v2: managed GPU node group (enable_gpu_node_group) ----
  # Auto Mode nodes bring their own networking and Pod Identity agent, but
  # node-group nodes don't, so they need these add-ons. before_compute installs
  # the CNI and the agent before the node group, so a new node can go Ready.
  addons = var.enable_gpu_node_group ? {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
  } : {}

  eks_managed_node_groups = var.enable_gpu_node_group ? {
    gpu = {
      name            = "gpu"
      use_name_prefix = false

      ami_type       = "BOTTLEROCKET_x86_64_NVIDIA"
      instance_types = [var.gpu_instance_type]

      # One GPU, ever. Starts empty; scale with
      #   aws eks update-nodegroup-config --scaling-config desiredSize=1 ...
      # (the module ignores desired_size after creation).
      min_size     = 0
      max_size     = 1
      desired_size = 0

      labels = {
        "eks-auto-llm/gpu" = "node-group"
      }
      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          effect = "NO_SCHEDULE"
        }
      }

      # The NVIDIA DRA driver and Bottlerocket's bundled device plugin must not
      # manage the same GPU. Needs Bottlerocket 1.63.0 or later.
      bootstrap_extra_args = <<-EOT
        [settings.kubelet-device-plugins.nvidia]
        enabled = false
      EOT

      # Bottlerocket keeps images on the data volume (xvdb), not the root one.
      block_device_mappings = {
        xvdb = {
          device_name = "/dev/xvdb"
          ebs = {
            volume_size           = var.gpu_data_volume_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  } : {}

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
