# EKS + EC2 Capacity Blocks for ML — GPU Worker Nodes

Repeatable Terraform to stand up an EKS cluster with a GPU-backed managed
node group that consumes an **EC2 Capacity Block for ML** reservation,
alongside a standard on-demand system node group for cluster addons.

Based on the AWS-maintained pattern:
https://aws-ia.github.io/terraform-aws-eks-blueprints/patterns/machine-learning/ml-capacity-block/

This has been run end-to-end against a live sandbox account (`test_mode`,
Kubernetes 1.36).

## 1. Capacity Blocks

Capacity Blocks are a *reservation product*, not a compute product. You pay
upfront for a guaranteed block of GPU instances (p4d/p4de/p5/p5e/p5en,
trn1/trn2, or UltraServer configurations) for a fixed start time and
duration (up to 8 weeks out, durations from a few hours to weeks). AWS
places the instances in the same UltraCluster for low-latency networking.

EKS has *native* support for this: an EKS managed node group (MNG) can
target a Capacity Block reservation directly, so when the reservation
becomes active, the ASG behind the MNG launches instances into it
automatically. Native EKS support for this is currently limited to
**us-east-1, us-east-2, and us-west-2** — check the AWS EKS docs for the
current region list before you design around this.

## 2. Services involved

| Service | Role |
|---|---|
| EC2 Capacity Blocks for ML | The underlying reservation product (purchased out-of-band, not via Terraform) |
| VPC (terraform-aws-modules/vpc) | Standard private/public subnet layout, one NAT GW for the demo |
| EKS (terraform-aws-modules/eks ~> 20.34) | Control plane (Kubernetes 1.36) + two managed node groups |
| EKS managed node group #1 (`system`) | Runs CoreDNS, EBS CSI controller, etc. Type/count set by `system_instance_type` / `system_node_count` |
| EKS managed node group #2 (`gpu_cbr`) | GPU instances launched against the Capacity Block (or ODCR in test mode), AL2023 NVIDIA-accelerated AMI |
| NVIDIA k8s-device-plugin (Helm) | Advertises `nvidia.com/gpu` as an allocatable resource to the scheduler |
| EBS CSI driver addon | Persistent storage for training checkpoints/datasets |
| IAM role + IRSA (`pod-identity.tf`) | Grants the EBS CSI controller AWS API access — see section 4 for why this is IRSA and not EKS Pod Identity |

## 3. Prerequisites

1. **A purchased Capacity Block reservation — unless you're testing first
   (recommended).** With `test_mode = true`, skip straight to
   `terraform apply`; a Terraform-managed ODCR stands in for the block (see
   section 5). For the real thing, there's no Terraform resource for
   `PurchaseCapacityBlock` (unlike a standard on-demand Capacity
   Reservation, which `aws_ec2_capacity_reservation` does support), so use
   `scripts/find-and-purchase-capacity-block.sh` to search offerings and
   purchase one. You need the resulting `CapacityReservationId` and the AZ
   it landed in before you set `test_mode = false` and `apply`.
2. Terraform >= 1.7, AWS provider ~> 5.70.
3. An IAM principal with permissions for EKS, EC2, VPC, IAM (role
   creation), and Capacity Reservation describe/use.
4. `kubectl`, `helm`, and `aws` CLI v2 locally. (The `helm` CLI isn't
   strictly required — Terraform's `helm_release` resource doesn't need it
   — but not having it makes cleaning up a failed Helm release much more
   annoying; see section 9.)
5. A vCPU/GPU service quota sufficient for the instance type. In
   `test_mode`, this means your account's **On-Demand G and VT instance
   quota** (quota code `L-DB2E81BA`) for whatever `gpu_instance_type` you
   pick — many accounts default to 0 in regions they haven't used GPU
   instances in before. Check and request an increase if needed:
   ```bash
   aws service-quotas get-service-quota --region <region> --service-code ec2 --quota-code L-DB2E81BA
   aws service-quotas request-service-quota-increase --region <region> --service-code ec2 --quota-code L-DB2E81BA --desired-value 8
   ```
   For a real Capacity Block, the block's own purchase-time admission check
   covers this — the quota above doesn't apply.
6. Know your reservation's **exact instance type and AZ** before writing
   `terraform.tfvars` — both are hard constraints on the node group.
7. **If deploying into an AWS Organizations sandbox/ISB-style account,
   check for restrictive Service Control Policies before you start** 

## 4. Design considerations

- **AZ pinning is mandatory, not advisory.** The GPU node group's
  `subnet_ids` must be restricted to the single AZ the Capacity Block was
  allocated to. If the ASG behind the MNG is allowed to pick from multiple
  AZs, it will intermittently try to launch in an AZ with no reserved
  capacity and fail with a fairly unhelpful
  `InvalidParameterException: The following supplied instance types do not
  exist ...`. This repo handles it by reordering the VPC module's AZ list
  so the reservation's AZ is always `private_subnets[0]`, and pinning the
  GPU node group to `element(module.vpc.private_subnets, 0)`.
- **Custom launch template is required.** EKS rejects a Capacity Block MNG
  without one. You don't have to hand-roll it: supplying
  `capacity_type`, `instance_market_options`, `capacity_reservation_specification`,
  taints, or labels to the `terraform-aws-modules/eks` node group causes the
  module to generate a launch template for you automatically.
- **`capacity_type = "CAPACITY_BLOCK"` + `instance_market_options.market_type
  = "capacity-block"` + `capacity_reservation_specification` must all be
  set together.** Missing any one of them gets the create request rejected
  outright, not silently ignored. In `test_mode`, `capacity_type` is
  `ON_DEMAND` and `instance_market_options` is omitted entirely — see
  `odcr.tf`.
- **The SCP needs `sts:AssumeRoleWithWebIdentity`,
  `sts:AssumeRole`, `sts:TagSession`, and `eks-auth:AssumeRoleForPodIdentity`
  added to its allow-list,
  since `iam:*` being fully allowed already means AWS Nuke can still find
  and delete any role these actions create.


- **Helm chart values: use a YAML `values` block, not `set` args, for
  anything that looks like a boolean.** Helm's `--set` (and Terraform's
  `helm_release.set` blocks) auto-coerce the strings `"true"`/`"false"` to
  real booleans. The NVIDIA device plugin chart's `nodeSelector` expects a
  map of strings, so `set { name = "nodeSelector.x", value = "true" }`
  fails with `cannot unmarshal bool into Go struct field
  PodSpec.spec.template.spec.nodeSelector of type string`. `addons.tf` uses
  a single `yamlencode()`'d `values` block instead, which has no such
  ambiguity.
- **A failed `helm_release` leaves state in two places.** If a
  `helm_release` resource fails, `terraform state rm` only clears
  Terraform's own bookkeeping — Helm tracks releases as labeled Secrets
  inside the cluster itself, independently of Terraform. A retried
  `terraform apply` will fail with `cannot re-use a name that is still in
  use` unless those secrets are cleaned up first:
  ```bash
  kubectl get secrets -n kube-system -l owner=helm,name=nvidia-device-plugin
  kubectl delete secrets -n kube-system -l owner=helm,name=nvidia-device-plugin
  ```
  Installing the `helm` CLI avoids this entirely (`helm uninstall
  nvidia-device-plugin -n kube-system`).
- **An interrupted `apply` mid-addon-creation taints the addon.** If an
  `aws_eks_addon` resource is stuck `Creating` (e.g. because the IAM role
  it needs doesn't exist yet — see the EBS CSI point above) and you
  interrupt or otherwise let the underlying issue get fixed out of band,
  Terraform will mark that addon `tainted` and destroy/recreate it on the
  next `apply`, even once it's actually healthy. This is expected
  bookkeeping cleanup, not a new bug — let it replace, it resolves in
  under 30 seconds.
- **Fixed lifecycle, not elastic.** A Capacity Block has a hard start and
  end time. `min_size = max_size = desired_size` in this repo reflects that
  reality — this is not a workload you autoscale up and down; it's a
  reservation you occupy for its duration. Don't put this node group behind
  Cluster Autoscaler or Karpenter's normal provisioning logic; if you're
  running Karpenter elsewhere in the cluster, exclude this reservation from
  its nodepools.
- **Handle the reservation's end proactively.** AWS does not gracefully
  drain your pods when the block expires — nodes are reclaimed. Put a
  `CronJob`/EventBridge rule in place to cordon + drain the GPU node group
  ahead of the `EndDate` on the reservation so checkpoints get saved and
  pods terminate cleanly rather than being killed mid-reclaim. This repo
  doesn't automate that for you since drain timing is workload-specific —
  add it before running anything long-lived against a real block.
- **Upgrades need `desired_size = 0` first.** If you ever need to update
  this MNG (new AMI release, taint changes) while a reservation is active,
  AWS requires the node group's desired size to be 0 before the update, then
  scaled back up — plan maintenance windows accordingly.
- **Separate system node group.** Keep CoreDNS, EBS CSI controller, and
  anything else the cluster needs to stay up outside the Capacity Block's
  lifecycle on ordinary on-demand nodes, as this repo does. Size it with
  `system_instance_type` / `system_node_count` — the defaults (`t3.medium`
  x1) are fine for a throwaway test but undersized for anything real (no
  redundancy at count 1).
- **AMI choice.** `AL2023_x86_64_NVIDIA` bundles the NVIDIA driver and
  container toolkit so you don't hand-roll driver installation via
  bootstrap scripts. You still need the k8s device plugin daemonset
  (`addons.tf`) to expose `nvidia.com/gpu` to the scheduler — the AMI having
  the driver doesn't make Kubernetes aware of the GPUs on its own, and the
  daemonset itself has to actually deploy successfully (see the Helm points
  above) before `kubectl describe node` will show `nvidia.com/gpu` under
  Capacity/Allocatable.
- **EFA / multi-node training.** If your reservation is for multiple
  EFA-capable instances (p4d/p4de/p5 families) and you're doing distributed
  training across them, set `enable_efa = true`. This opens the required
  security group rules and exposes the EFA interfaces on the launch
  template. Single-instance or inference-only workloads can leave it off.
- **Cost.** You pay the full upfront Capacity Block fee regardless of
  utilisation once purchased — an idle GPU node group here is still fully
  billed. There's no equivalent of stopping the meter by scaling the ASG to
  zero; the reservation clock runs independent of what Kubernetes is doing.
- **EKS control plane upgrades are one minor version at a time, no
  exceptions.** `UpdateClusterVersion` rejects multi-version jumps outright
  — going from 1.32 to 1.36 in place means four sequential upgrades
  (1.32→1.33→1.34→1.35→1.36), each 20-45 minutes plus a node group rolling
  replacement and add-on compatibility check per step. For disposable
  infrastructure like a `test_mode` stack, it's far simpler to
  `terraform destroy` and recreate at the target version than to step
  through an in-place upgrade chain.

## 5. Testing without a real Capacity Block

`test_mode = true` skips purchasing a Capacity Block entirely. `odcr.tf`
instead creates a standard `aws_ec2_capacity_reservation` — a normal
Terraform resource, no upfront purchase, no fixed start/end window, billed
hourly for whatever `gpu_instance_type` you choose (default `g4dn.xlarge`,
~$0.53/hr on-demand, vs $60+/hr for a `p5.48xlarge`), and gone the moment
you `terraform destroy` or remove it.

This exercises exactly the mechanics most likely to break in the real
thing — AZ-pinned subnets, `capacity_reservation_specification` targeting,
the auto-generated custom launch template, taints/labels, IAM auth for the
EBS CSI driver, and the NVIDIA device plugin actually advertising
`nvidia.com/gpu`. It does **not** test `capacity_type = "CAPACITY_BLOCK"`,
the `capacity-block` market type, or the fixed reservation lifecycle —
those only exist on a real block, and there's no way around eventually
testing against one if that lifecycle behaviour matters for your use case
(e.g. the forced-drain-before-expiry logic).

To switch to a real Capacity Block later: buy one with
`scripts/find-and-purchase-capacity-block.sh`, then edit
`terraform.tfvars` — comment out the entire test-mode block and uncomment /
fill in the real-Capacity-Block block instead (they're mutually exclusive;
having both active causes a duplicate-argument error). Make sure `region`
matches the reservation's region **and** is one of us-east-1/us-east-2/
us-west-2 (see section 1). `terraform plan` will show the GPU node group's
launch template being replaced (capacity_type and market_type change) —
expect a brief GPU node replacement, not a full cluster rebuild, assuming
the rest of the config (VPC, cluster version, etc.) is unchanged.

### Cost of a test_mode run (approximate on-demand rates)

| Resource | Rate | Notes |
|---|---|---|
| EKS control plane | $0.10/hr | Fixed, unavoidable (standard support pricing — see the K8s version note below) |
| `g4dn.xlarge` GPU node | ~$0.526/hr | Billed by the ODCR whether or not a pod is running on it |
| `t3.medium` system node x1 | ~$0.0416/hr | Scales with `system_node_count` |
| NAT Gateway | ~$0.045/hr + data | `single_nat_gateway = true` already minimises this |
| **Total** | **~$0.71/hr** | Plus negligible EBS/data transfer |

Destroy immediately after validating (section 8) rather than leaving it
running — none of this has a fixed minimum term, so a 20-30 minute test
costs well under $1.

## 6. Kubernetes version

`variables.tf` defaults `cluster_version` to **1.36**, 

Check current standard-support versions before relying on 1.36 remaining
current:
```bash
aws eks describe-cluster-versions --region <region> --query "clusterVersions[?status=='STANDARD_SUPPORT'].clusterVersion"
```

## 7. Deploy steps

```bash
# 1. Find and purchase the Capacity Block (one-time, out of band) - skip
#    entirely if using test_mode
cd scripts
./find-and-purchase-capacity-block.sh us-east-2 p5.48xlarge 1 24
cd ..

# 2. Populate terraform.tfvars - see terraform.tfvars.example for the
#    test-mode vs real-Capacity-Block blocks (only one active at a time)
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 3. Standard Terraform flow
terraform init
terraform plan -out=tfplan
terraform apply "tfplan"

# 4. Point kubectl at the new cluster
aws eks update-kubeconfig --region <region> --name <name>

# 5. Confirm the GPU node is Ready (in real-Capacity-Block mode, it will
#    only actually appear once the reservation's start time has passed and
#    the ASG can launch into it - if you apply before the start time, the
#    ASG will sit at 0/desired until the block goes active; not an issue in
#    test_mode since the ODCR is active immediately)
kubectl get nodes -l nvidia.com/gpu.present=true

# 6. Confirm nvidia.com/gpu is schedulable
kubectl apply -f manifests/gpu-smi-test-job.yaml
kubectl logs job/nvidia-smi-test
```

If you `apply` before a real reservation's start time, Terraform succeeds
(the node group and ASG exist), but the ASG won't actually be able to
launch instances until the block activates — this is expected, not a bug.
Time your `apply` so it's in place a little ahead of the start time; AWS's
own guidance is to use scheduled scaling so retries against transient
launch failures at the exact activation moment are handled for you.

## 8. Validation suite

Beyond the basic `nvidia-smi` check, `manifests/` includes tests that catch
the failure modes most specific to this stack:

| Test | Proves |
|---|---|
| `gpu-smi-test-job.yaml` | GPU is visible to the container runtime |
| `gpu-vectoradd-test.yaml` | GPU can actually run a CUDA kernel, not just report driver info |
| `taint-negative-test.yaml` | An untolerated pod never lands on the GPU node — check which node it actually scheduled to (`kubectl get nodes -L nvidia.com/gpu.present`), don't assume it must stay `Pending`; on a multi-node cluster it will correctly land on the system node instead |
| `gpu-exclusivity-test.yaml` | Device plugin correctly reports 1 GPU on `g4dn.xlarge` - a 2nd pod requesting a GPU must stay `Pending` |
| `ebs-csi-test.yaml` | EBS CSI addon actually provisions and mounts a volume |
| Node replacement (see below, no manifest) | A replaced GPU instance re-targets the same capacity reservation, not just the first launch |

```bash
kubectl apply -f manifests/gpu-vectoradd-test.yaml
kubectl wait --for=condition=complete job/gpu-vectoradd-test --timeout=120s
kubectl logs job/gpu-vectoradd-test   # expect "Test PASSED"

kubectl apply -f manifests/taint-negative-test.yaml
kubectl get nodes -L nvidia.com/gpu.present
kubectl describe pod taint-negative-test   # confirm the Node it landed on is NOT the GPU one

kubectl apply -f manifests/gpu-exclusivity-test.yaml
kubectl get pods -l test=gpu-exclusivity   # expect one Running, one Pending

kubectl apply -f manifests/ebs-csi-test.yaml
kubectl logs ebs-csi-test-pod              # expect the test string
```

Node replacement test (confirms the launch template keeps targeting the
reservation after the first instance, not just once):

```bash
aws ec2 describe-instances --filters "Name=tag:eks:nodegroup-name,Values=gpu_cbr" --query "Reservations[].Instances[].InstanceId" --output text
aws ec2 terminate-instances --instance-ids <instance-id>
kubectl get nodes -w
aws ec2 describe-instances --filters "Name=tag:aws:eks:cluster-name,Values=<name>" "Name=instance-type,Values=<gpu-instance-type>" --query "Reservations[].Instances[].CapacityReservationId" --output text
```

Clean up all test resources before `terraform destroy`:
```bash
kubectl delete job gpu-vectoradd-test gpu-smi-test 2>$null
kubectl delete pod taint-negative-test ebs-csi-test-pod 2>$null
kubectl delete pods -l test=gpu-exclusivity 2>$null
kubectl delete pvc ebs-csi-test-pvc 2>$null
```


## 9. Teardown

```bash
# Drain the GPU node group first if anything is running on it
kubectl drain -l nvidia.com/gpu.present=true --ignore-daemonsets --delete-emptydir-data

terraform destroy
```

In `test_mode`, this also removes the Terraform-managed ODCR, so billing
stops the moment `destroy` completes. Destroying the Terraform stack does
**not** cancel or refund a real Capacity Block reservation — that's a
separate, non-refundable purchase managed through EC2, not through this
stack. Terraform only controls what runs inside the reservation while it's
active.

## 11. File layout

```
.
├── versions.tf                  # providers + backend stub
├── variables.tf
├── vpc.tf                       # AZ-ordering trick so reservation AZ = subnets[0]
├── eks.tf                       # cluster + system node group + GPU CBR node group
├── odcr.tf                      # test_mode: Terraform-managed ODCR stand-in for a real Capacity Block
├── pod-identity.tf              # IAM role + IRSA trust policy + SA annotation for the EBS CSI driver
├── addons.tf                    # NVIDIA device plugin (Helm, YAML values block)
├── outputs.tf
├── terraform.tfvars.example     # test-mode and real-Capacity-Block variable blocks
├── manifests/
│   ├── gpu-smi-test-job.yaml
│   ├── gpu-vectoradd-test.yaml
│   ├── taint-negative-test.yaml
│   ├── gpu-exclusivity-test.yaml
│   └── ebs-csi-test.yaml
└── scripts/
    └── find-and-purchase-capacity-block.sh
```
