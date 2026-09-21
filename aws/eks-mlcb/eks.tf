module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.34"

  cluster_name    = var.name
  cluster_version = var.cluster_version

  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true
  cluster_endpoint_public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  cluster_enabled_log_types                = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  bootstrap_self_managed_addons   = false
  enable_irsa                     = true
  enable_security_groups_for_pods = true

  cluster_addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
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

  # EFA support at the cluster level opens the required SG rules for
  # inter-node EFA traffic when a node group requests it.
  enable_efa_support = var.enable_efa

  eks_managed_node_group_defaults = {
    node_repair_config = {
      enabled = true
    }
  }

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
      # for how private_subnets[0] is guaranteed to be that AZ.
      subnet_ids = [element(module.vpc.private_subnets, 0)]

      enable_efa_support = var.enable_efa

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
        "nvidia.com/gpu.present"         = "true"
        "vpc.amazonaws.com/efa.present"  = tostring(var.enable_efa)
        "capacity-type"                  = "capacity-block"
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
      capacity_type = var.test_mode ? "ON_DEMAND" : "CAPACITY_BLOCK"
      instance_market_options = var.test_mode ? {} : {
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
