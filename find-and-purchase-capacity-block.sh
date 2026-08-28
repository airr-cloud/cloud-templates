#!/usr/bin/env bash
# There is no Terraform resource to purchase a Capacity Block (as opposed to
# a regular On-Demand Capacity Reservation, which aws_ec2_capacity_reservation
# does support). Purchasing is a one-time, human-in-the-loop action - do it
# here, then feed the resulting reservation ID into terraform.tfvars.
#
# Usage:
#   ./find-and-purchase-capacity-block.sh <region> <instance-type> <instance-count> <duration-hours>
#
# Example:
#   ./find-and-purchase-capacity-block.sh us-east-2 p5.48xlarge 1 24

set -euo pipefail

REGION="${1:?region required, e.g. us-east-2}"
INSTANCE_TYPE="${2:?instance type required, e.g. p5.48xlarge}"
INSTANCE_COUNT="${3:?instance count required, e.g. 1}"
DURATION_HOURS="${4:?duration in hours required, e.g. 24}"

echo "==> Searching for available Capacity Block offerings..."
aws ec2 describe-capacity-block-offerings \
  --region "$REGION" \
  --instance-type "$INSTANCE_TYPE" \
  --instance-count "$INSTANCE_COUNT" \
  --capacity-duration-hours "$DURATION_HOURS" \
  --output table

cat <<'EOF'

Review the offerings above. Each has a CapacityBlockOfferingId, a StartDate,
and an UpfrontFee. Pricing is fixed and paid upfront - there is no way to
"try before you buy". Confirm start time, AZ and price before purchasing.

To purchase a specific offering:

  aws ec2 purchase-capacity-block \
    --region <region> \
    --capacity-block-offering-id <offering-id-from-above> \
    --instance-platform Linux/UNIX

The response includes a CapacityReservation.CapacityReservationId (looks
like cr-xxxxxxxxxxxxxxxxx) and the AvailabilityZone it was placed in.
Put both values into terraform.tfvars as capacity_reservation_id and
capacity_reservation_availability_zone.

Capacity Blocks can be purchased up to 8 weeks ahead. The Terraform in this
repo should be applied AFTER purchase (so the AZ is known) but ideally BEFORE
the reservation's start time, so the node group is ready to launch instances
the moment the block becomes active.
EOF
