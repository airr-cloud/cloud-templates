# The AL2023_x86_64_NVIDIA AMI ships the NVIDIA driver and container runtime,
# but something still has to advertise nvidia.com/gpu as an allocatable
# Kubernetes resource - that's the NVIDIA k8s-device-plugin daemonset.
resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.17.1"
  namespace        = "kube-system"
  create_namespace = false

  # Using a YAML values block instead of individual `set` args - `set` auto-
  # coerces "true"/"false" strings to booleans, which breaks nodeSelector
  # (a map of strings) and can break toleration values the same way.
  values = [
    yamlencode({
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
      ]
      nodeSelector = {
        "nvidia.com/gpu.present" = "true"
      }
    })
  ]

  depends_on = [module.eks]
}