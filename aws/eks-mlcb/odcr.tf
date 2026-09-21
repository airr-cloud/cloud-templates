# Only created when var.test_mode = true. This is a standard On-Demand
# Capacity Reservation - fully managed by Terraform, no upfront purchase,
# no fixed lifecycle. It's billed hourly at the instance's on-demand rate
# for as long as it exists (whether or not a node is actually running
# against it), so keep gpu_instance_type small while testing and
# `terraform destroy` (or just delete this resource) when you're done.
#
# It exercises the same node-group mechanics as a real Capacity Block:
# AZ-pinned subnet, capacity_reservation_specification targeting, custom
# launch template. It does NOT exercise: capacity_type = "CAPACITY_BLOCK",
# instance_market_options.market_type = "capacity-block", or the fixed
# start/end lifecycle - those only exist for real Capacity Blocks.
resource "aws_ec2_capacity_reservation" "test_gpu" {
  count = var.test_mode ? 1 : 0

  instance_type           = var.gpu_instance_type
  instance_platform       = "Linux/UNIX"
  availability_zone       = local.azs[0]
  instance_count          = var.gpu_node_desired_count
  instance_match_criteria = "targeted" # requires explicit targeting, just like a Capacity Block
  end_date_type           = "unlimited"

  tags = merge(var.tags, { Name = "${var.name}-test-odcr" })
}

locals {
  # Real Capacity Block ID in production mode, Terraform-managed ODCR ID in test mode
  effective_capacity_reservation_id = var.test_mode ? aws_ec2_capacity_reservation.test_gpu[0].id : var.capacity_reservation_id
}
