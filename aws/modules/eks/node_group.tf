# ***************************************
# Node Group
# ***************************************
resource "time_sleep" "this" {
  create_duration = "30s"

  triggers = {
    cluster_name     = aws_eks_cluster.this.name
    cluster_endpoint = aws_eks_cluster.this.endpoint
    cluster_version  = aws_eks_cluster.this.version

    cluster_certificate_authority_data = aws_eks_cluster.this.certificate_authority[0].data
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name = var.eks_cluster_name
  subnet_ids   = var.vpc_private_subnet_ids

  node_role_arn = aws_iam_role.node_group_role.arn

  scaling_config {
    min_size     = var.node_group_min_size
    max_size     = var.node_group_max_size
    desired_size = var.node_group_desired_size
  }

  node_group_name = "eks-node-group"

  ami_type = var.node_group_ami_type
  version  = var.eks_cluster_version

  capacity_type  = var.node_group_capacity_type
  disk_size      = var.node_group_disk_size
  instance_types = var.node_group_instance_types

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.default_version
  }

  update_config {
    max_unavailable_percentage = var.node_group_max_unavailable_percentage
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    var.eks_tags,
    { Name = "eks-node-group" }
  )

  depends_on = [
    aws_eks_cluster.this
  ]
}

# ***************************************
# Node Group IAM Role
# ***************************************
data "aws_iam_policy_document" "node_group_assume_role_policy" {
  statement {
    sid     = "EKSNodeAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node_group_role" {
  name_prefix = "eks-node-group-"
  description = "EKS managed node group IAM role"

  assume_role_policy    = data.aws_iam_policy_document.node_group_assume_role_policy.json
  force_detach_policies = true

  tags = var.eks_tags
}

resource "aws_iam_role_policy_attachment" "node_group_role_attachment" {
  for_each = tomap({
    AmazonEKSWorkerNodePolicy          = "${local.iam_role_policy_prefix}/AmazonEKSWorkerNodePolicy"
    AmazonEC2ContainerRegistryReadOnly = "${local.iam_role_policy_prefix}/AmazonEC2ContainerRegistryReadOnly"
    AmazonEKS_CNI_Policy               = "${local.iam_role_policy_prefix}/AmazonEKS_CNI_Policy"
    AmazonEBSCSIDriverPolicy           = "${local.iam_role_policy_prefix}/service-role/AmazonEBSCSIDriverPolicy"
  })

  policy_arn = each.value
  role       = aws_iam_role.node_group_role.name
}

# ***************************************
# Node Group Launch template
# ***************************************
resource "aws_launch_template" "this" {
  name_prefix            = "eks-node-group-"
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.node.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      var.eks_tags,
      { Name = "eks-node-group" }
    )
  }

  # Prevent premature access of policies by pods that
  # require permissions on create/destroy that depend on nodes
  depends_on = [
    aws_iam_role_policy_attachment.this,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# ***************************************
# Node Security Group
# Generally follows https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html
# ***************************************
locals {
  node_sg_name = "${var.eks_cluster_name}-node"

  node_security_group_rules = {
    ingress_cluster_443 = {
      description                   = "Cluster API to node groups"
      protocol                      = "tcp"
      from_port                     = 443
      to_port                       = 443
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_cluster_kubelet = {
      description                   = "Cluster API to node kubelets"
      protocol                      = "tcp"
      from_port                     = 10250
      to_port                       = 10250
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_self_coredns_tcp = {
      description = "Node to node CoreDNS"
      protocol    = "tcp"
      from_port   = 53
      to_port     = 53
      type        = "ingress"
      self        = true
    }
    ingress_self_coredns_udp = {
      description = "Node to node CoreDNS UDP"
      protocol    = "udp"
      from_port   = 53
      to_port     = 53
      type        = "ingress"
      self        = true
    }
  }

  node_application_rules = {
    ingress_nodes_ephemeral = {
      description = "Node to node ingress on ephemeral ports"
      protocol    = "tcp"
      from_port   = 1025
      to_port     = 65535
      type        = "ingress"
      self        = true
    }
    # Metrics Server (for HPA)
    ingress_cluster_4443_webhook = {
      description                   = "Cluster API to node 4443/tcp webhook"
      protocol                      = "tcp"
      from_port                     = 4443
      to_port                       = 4443
      type                          = "ingress"
      source_cluster_security_group = true
    }
    # Prometheus
    ingress_cluster_6443_webhook = {
      description                   = "Cluster API to node 6443/tcp webhook"
      protocol                      = "tcp"
      from_port                     = 6443
      to_port                       = 6443
      type                          = "ingress"
      source_cluster_security_group = true
    }
    # AWS Load Balancer Controller
    ingress_cluster_9443_webhook = {
      description                   = "Cluster API to node 9443/tcp webhook"
      protocol                      = "tcp"
      from_port                     = 9443
      to_port                       = 9443
      type                          = "ingress"
      source_cluster_security_group = true
    }
    # ArgoCD / Chirpstack / Grafana
    ingress_cluster_8080_webhook = {
      description                   = "Cluster API to node 8080/tcp webhook"
      protocol                      = "tcp"
      from_port                     = 8080
      to_port                       = 8080
      type                          = "ingress"
      source_cluster_security_group = true
    }
    egress_all = {
      description = "Allow all egress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}

resource "aws_security_group" "node" {
  name        = local.node_sg_name
  description = "EKS node shared security group"
  vpc_id      = var.vpc_id

  tags = merge(
    var.eks_tags,
    {
      "Name"                                          = local.node_sg_name
      "kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
    },
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "node" {
  for_each = { for k, v in merge(
    local.node_security_group_rules,
    local.node_application_rules,
  ) : k => v }

  # Required
  security_group_id = aws_security_group.node.id
  protocol          = each.value.protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  type              = each.value.type

  # Optional
  description              = lookup(each.value, "description", null)
  cidr_blocks              = lookup(each.value, "cidr_blocks", null)
  ipv6_cidr_blocks         = lookup(each.value, "ipv6_cidr_blocks", null)
  prefix_list_ids          = lookup(each.value, "prefix_list_ids", null)
  self                     = lookup(each.value, "self", null)
  source_security_group_id = try(each.value.source_cluster_security_group, false) ? aws_security_group.cluster.id : lookup(each.value, "source_security_group_id", null)
}
