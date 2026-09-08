data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = var.test_mode ? slice(data.aws_availability_zones.available.names, 0, 3) : distinct(concat(
    [var.capacity_reservation_availability_zone],
    slice(data.aws_availability_zones.available.names, 0, 3)
  ))
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Required for the EKS control plane and internal ELB/ALB discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = var.tags
}
