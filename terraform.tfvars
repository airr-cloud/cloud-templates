# --- Deployment A: cheapest test mode (default) - no real Capacity Block needed ---
# Creates a Terraform-managed on-demand Capacity Reservation instead, using
# the cheapest widely-available GPU type and a minimal system node group.
# Validates all the node group / AZ-pinning / device-plugin mechanics for
# roughly $0.60-0.70/hr all-in (see README cost breakdown), destroyable any
# time.
# If using the test, # out lines 25-34 below.

region                 = "eu-west-1"   # cheapest / most capacity-plentiful region generally
name                   = "gpu-cbr-demo"
test_mode              = true
gpu_instance_type      = "g4dn.xlarge"
gpu_node_desired_count = 1
system_instance_type   = "t3.medium"
system_node_count      = 1
enable_efa             = false
#cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

# --- Real Capacity Block deployment ---
# Purchase the reservation first via scripts/find-and-purchase-capacity-block.sh,
# then fill in capacity_reservation_id and capacity_reservation_availability_zone
# below. region must match the reservation's region.
# If using a real capacity block # out lines 9-16 and uncomment lines 25-34 below.


# region                                  = "us-east-2"   # must match the Capacity Block's region - also must be us-east-1/us-east-2/us-west-2 for native EKS CBR support
# name                                    = "gpu-cbr-demo"
# test_mode                               = false
# capacity_reservation_id                 = "cr-0123456789abcdef0"
# capacity_reservation_availability_zone  = "us-east-2b"
# gpu_instance_type                       = "p5.48xlarge"
# gpu_node_desired_count                  = 1
# system_instance_type                    = "t3.medium"    # consider bumping for a real workload
# system_node_count                       = 2               # consider 2 for redundancy in real use
# enable_efa                              = false           # set true if training across multiple EFA-capable instances
#cluster_endpoint_public_access_cidrs = [""]