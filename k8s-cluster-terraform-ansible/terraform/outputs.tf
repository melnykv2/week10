output "controller_public_ips" {
  description = "Elastic IPs of the control plane nodes (Kubernetes API endpoint)"
  value       = aws_eip.controller[*].public_ip
}

output "controller_private_ips" {
  value = aws_instance.controller[*].private_ip
}

output "worker_public_ips" {
  value = aws_instance.worker[*].public_ip
}

output "worker_private_ips" {
  value = aws_instance.worker[*].private_ip
}

output "worker_pod_cidrs" {
  value = local.worker_pod_cidrs
}

output "kubernetes_api_endpoint" {
  value = "https://${aws_eip.controller[0].public_ip}:6443"
}

output "ssh_controller" {
  value = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_eip.controller[0].public_ip}"
}

output "ansible_inventory" {
  value = abspath(local_file.ansible_inventory.filename)
}
