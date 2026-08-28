# --- EBS snapshot backups via DLM -------------------------------------
# Dynamically-provisioned PVs aren't backed up by anything by default.
# This tags volumes created via the "gp2-backed-up" StorageClass and
# snapshots them daily via DLM. Customer workloads that want backup
# coverage should request that StorageClass in their PVCs instead of
# the plain "gp2" one the EBS CSI addon ships with.

resource "aws_iam_role" "dlm" {
  name = "${var.name}-dlm-lifecycle"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "dlm.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "ebs_daily" {
  description        = "Daily EBS snapshots for tagged ${var.name} volumes"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "true"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"] # low-traffic UTC hour; adjust if needed
      }

      retain_rule {
        count = 14 # 2 weeks of daily snapshots
      }

      tags_to_add = {
        SnapshotCreator = "dlm-${var.name}"
      }

      copy_tags = true
    }
  }

  tags = var.tags
}

# StorageClass that tags its volumes so DLM's target_tags selects them.
# Customer PVCs use storageClassName: gp2-backed-up instead of gp2 to opt in.
resource "kubernetes_storage_class_v1" "gp2_backed_up" {
  metadata {
    name = "gp2-backed-up"
  }
  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Retain" # don't delete the volume (and its snapshots) when the PVC is deleted
  volume_binding_mode = "WaitForFirstConsumer"
  parameters = {
    type                     = "gp2"
    "csi.storage.k8s.io/fstype" = "ext4"
    tagSpecification_1       = "Backup=true"
  }

  depends_on = [module.eks]
}
