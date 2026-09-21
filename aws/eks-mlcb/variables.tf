variable "region" {
  description = "AWS region. Must be a region where Capacity Blocks for ML and native EKS support exist (currently us-east-1, us-east-2, us-west-2 for the EKS-native path; check current AWS docs before relying on this elsewhere)."
  type        = string
  default     = "us-east-2"
}

variable "name" {
  description = "Base name used for the cluster and tagged resources"
  type        = string
  default     = "gpu-cbr-demo"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the demo VPC"
  type        = string
  default     = "10.60.0.0/16"
}

# --- Capacity Block specific inputs -----------------------------------------
# You cannot purchase a Capacity Block via Terraform. You purchase it out-of-band via the
# console or `aws ec2 purchase-capacity-block` (see scripts/find-and-purchase-capacity-block.sh),
# then feed the resulting reservation ID into this module.

variable "test_mode" {
  description = <<-EOT
    If true, skips real Capacity Blocks entirely and creates a normal
    aws_ec2_capacity_reservation (a standard ODCR) instead - fully
    Terraform-managed, no upfront purchase, no fixed start/end window,
    billed hourly for whatever gpu_instance_type you pick and destroyable
    any time via `terraform destroy`. Use this to validate the node group /
    AZ-pinning / launch-template / device-plugin mechanics cheaply with a
    small instance type (e.g. g4dn.xlarge) before ever purchasing a real
    Capacity Block. Set to false and supply capacity_reservation_id +
    capacity_reservation_availability_zone for the real thing.
  EOT
  type    = bool
  default = true
}

variable "capacity_reservation_id" {
  description = "The ID of a purchased EC2 Capacity Block reservation (e.g. cr-0123456789abcdef0). Only used when test_mode = false."
  type        = string
  default     = null
}

variable "capacity_reservation_availability_zone" {
  description = "The single AZ the Capacity Block was purchased in. Only used when test_mode = false - in test_mode the AZ is picked automatically. The GPU node group's subnet MUST be restricted to this AZ either way."
  type        = string
  default     = null
}

variable "gpu_instance_type" {
  description = "GPU instance type. In test_mode, pick something cheap (g4dn.xlarge is the cheapest widely-available GPU instance, ~$0.53/hr on-demand in us-east-1). For a real Capacity Block, this MUST match the reservation exactly (e.g. p5.48xlarge, p4d.24xlarge, trn1.32xlarge)."
  type        = string
  default     = "g4dn.xlarge"
}

variable "system_instance_type" {
  description = "Instance type for the non-GPU system node group (CoreDNS, EBS CSI controller). t3.medium is cheap (~$0.0416/hr) and sufficient for a test deployment."
  type        = string
  default     = "t3.medium"
}

variable "system_node_count" {
  description = "Node count for the system node group. 1 is enough for a throwaway test deployment; use 2 for anything you'd call resilient."
  type        = number
  default     = 1
}

variable "gpu_node_desired_count" {
  description = "Number of GPU instances to run - should match (or be <=) the quantity reserved in the Capacity Block"
  type        = number
  default     = 1
}

variable "enable_efa" {
  description = "Whether to enable EFA networking on the GPU node group (relevant for multi-node distributed training on instance types that support EFA, e.g. p5/p4d families)"
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API endpoint. Restrict this to known egress IPs (office/VPN) rather than leaving it open to 0.0.0.0/0 - especially important for a cluster expected to run for months rather than a same-day test."
  type        = list(string)
  default     = ["0.0.0.0/0"] # override in terraform.tfvars with real CIDRs before any longer-lived deployment
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "eks-gpu-capacity-block"
    ManagedBy   = "terraform"
  }
}
