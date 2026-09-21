output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Run this to update your local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "gpu_node_group_asg" {
  description = "Underlying Auto Scaling Group name for the Capacity Block GPU node group - useful for CloudWatch/lifecycle automation"
  value       = module.eks.eks_managed_node_groups["gpu_cbr"].node_group_autoscaling_group_names
}
