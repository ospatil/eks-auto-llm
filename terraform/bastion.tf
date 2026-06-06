# Minimal SSM tunnel target.
#
# This is NOT a full bastion: nothing is installed on it and it has no cluster
# access. Its only job is to be an SSM-managed EC2 instance inside the VPC so
# you can open an `AWS-StartPortForwardingSessionToRemoteHost` tunnel from your
# laptop to the PRIVATE EKS API endpoint (port 443). kubectl/helm then run on
# your laptop through that tunnel. (SSM cannot tunnel into a VPC without some
# compute running the agent - there is no agentless path - so one tiny instance
# is the minimum.)
#
# No SSH key, no public IP, no inbound ports, no user-data tooling. AL2023 ships
# the SSM agent preinstalled and running.

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "bastion_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.project}-ssm-tunnel"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume.json
}

# Only SSM core - enough to be a Session Manager target. No cluster access.
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.project}-ssm-tunnel"
  role = aws_iam_role.bastion.name
}

# No ingress; egress all (reaches SSM endpoints + forwards to the EKS API ENI).
resource "aws_security_group" "bastion" {
  name_prefix = "${var.project}-ssm-tunnel-"
  description = "SSM tunnel target - no inbound, egress all"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-ssm-tunnel" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.bastion_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  metadata_options {
    http_tokens   = "required" # IMDSv2
    http_endpoint = "enabled"
  }

  tags = { Name = "${var.project}-ssm-tunnel" }
}

# NOTE: no EKS access entry for this instance. Your laptop's IAM identity (the
# one that ran `apply`) is already cluster-admin via
# enable_cluster_creator_admin_permissions, and that's the identity kubectl uses
# through the tunnel. The instance only forwards TCP - it never authenticates to
# the cluster.
