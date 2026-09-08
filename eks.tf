module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  # v21 stripped the `cluster_*` prefix from these to match the underlying API.
  name               = var.name
  kubernetes_version = var.cluster_version

  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = var.cluster_endpoint_public_access_cidrs
  enabled_log_types                        = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  enable_irsa = true

  # v21 removed `enable_security_groups_for_pods`. All that flag ever did was
  # attach this managed policy to the cluster IAM role, so attach it directly to
  # keep SecurityGroupPolicy (security groups for pods) working.
  iam_role_additional_policies = {
    AmazonEKSVPCResourceController = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  }

  # `bootstrap_self_managed_addons = false` is gone: v21 hardcodes it to false and
  # adds it to the cluster's ignore_changes, so the old argument is redundant.

  # `most_recent` now defaults to true in v21 (was false). Pinned back to false on
  # the addons that previously relied on that default so this upgrade doesn't also
  # bump addon versions - drop these lines to adopt the v21 default deliberately.
  addons = {
    coredns = {
      most_recent = false
    }
    eks-pod-identity-agent = {
      most_recent    = false
      before_compute = true
    }
    kube-proxy = {
      most_recent = false
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # NOTE: the cluster-level `enable_efa_support` argument no longer exists. In v21
  # each node group creates its own security group carrying the node-to-node EFA
  # rules, so setting `enable_efa_support` on the GPU group below is sufficient -
  # and it no longer opens those rules across every node group.

  # NOTE: `eks_managed_node_group_defaults` was removed in v21 (the node group
  # variable is now a strongly-typed object). Anything that lived there has to be
  # set per group - see `node_repair_config` on both groups below.

  eks_managed_node_groups = {

    # ---------------------------------------------------------------------
    # System node group: runs CoreDNS, EBS CSI controller, cluster-autoscaler
    # (if added), etc. Kept off the GPU capacity so those pods are never at
    # risk of the Capacity Block's fixed lifecycle.
    # ---------------------------------------------------------------------
    system = {
      instance_types = [var.system_instance_type]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = var.system_node_count
      max_size     = var.system_node_count + 1
      desired_size = var.system_node_count

      node_repair_config = {
        enabled = true
      }

      # --- v21 default changes, pinned back to the v20 values --------------
      # Each of these feeds the launch template, so letting them flip would
      # roll the nodes as part of the module upgrade itself. Change them
      # deliberately, in a separate commit, not as a side effect of this one.
      use_latest_ami_release_version = false # v21 default: true
      enable_monitoring              = true  # v21 default: false
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2 # v21 default: 1
      }
    }

    # ---------------------------------------------------------------------
    # GPU node group backed by the EC2 Capacity Block reservation.
    #
    # Key requirements (all enforced by the arguments below):
    #  1. subnet_ids restricted to the single AZ the CBR was purchased in
    #  2. capacity_type = "CAPACITY_BLOCK"
    #  3. instance_market_options.market_type = "capacity-block"
    #  4. capacity_reservation_specification targets the reservation ID
    #  5. A custom launch template is mandatory for Capacity Block MNGs -
    #     the module generates one automatically because we've supplied
    #     launch-template-only arguments (taints, labels, capacity_type, etc.)
    # ---------------------------------------------------------------------
    gpu_cbr = {
      ami_type       = "AL2023_x86_64_NVIDIA" # bundled NVIDIA driver + container toolkit
      instance_types = [var.gpu_instance_type]

      min_size     = var.gpu_node_desired_count
      max_size     = var.gpu_node_desired_count
      desired_size = var.gpu_node_desired_count

      # Restrict to the reservation's AZ - this is not optional. See vpc.tf
      # for how private_subnets[0] is guaranteed to be that AZ. v21 no longer
      # auto-selects a subnet for EFA/placement groups, so this is now load
      # bearing for two reasons rather than one.
      subnet_ids = [element(module.vpc.private_subnets, 0)]

      enable_efa_support = var.enable_efa
      enable_efa_only    = false # v21 default: true

      node_repair_config = {
        enabled = true
      }

      # --- v21 default changes, pinned back to the v20 values --------------
      # Especially important here: an AMI release version change replaces the
      # GPU nodes, and these nodes sit on fixed-lifecycle reserved capacity.
      use_latest_ami_release_version = false # v21 default: true
      enable_monitoring              = true  # v21 default: false
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2 # v21 default: 1
      }

      # RAID0 the local NVMe instance store for kubelet/containerd - standard
      # practice on p4d/p5 class instances that ship with local NVMe.
      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              instance:
                localStorage:
                  strategy: RAID0
          EOT
        }
      ]

      labels = {
        "nvidia.com/gpu.present"        = "true"
        "vpc.amazonaws.com/efa.present" = tostring(var.enable_efa)
        "capacity-type"                 = "capacity-block"
      }

      # Keep general workloads off the reserved GPU capacity
      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      # test_mode: plain ODCR, ON_DEMAND capacity_type, no market_type override
      # real block: CAPACITY_BLOCK capacity_type + capacity-block market type
      #
      # v21 types this as an object, so "unset" is now `null` rather than `{}`.
      capacity_type = var.test_mode ? "ON_DEMAND" : "CAPACITY_BLOCK"
      instance_market_options = var.test_mode ? null : {
        market_type = "capacity-block"
      }
      capacity_reservation_specification = {
        capacity_reservation_target = {
          capacity_reservation_id = local.effective_capacity_reservation_id
        }
      }
    }
  }

  tags = var.tags
}
