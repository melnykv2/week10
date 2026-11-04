variable "region" {
  description = "AWS region to deploy the cluster into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used for names and tags of all resources"
  type        = string
  default     = "k8s-hard-way"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC"
  type        = string
  default     = "10.240.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block of the subnet that hosts all cluster nodes"
  type        = string
  default     = "10.240.0.0/24"
}

variable "cluster_cidr" {
  description = "Pod network CIDR; every worker gets a /24 out of it"
  type        = string
  default     = "10.200.0.0/16"
}

variable "controller_count" {
  description = "Number of control plane nodes (each also runs an etcd member)"
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "controller_instance_type" {
  description = "EC2 instance type for control plane nodes"
  type        = string
  default     = "t3.small"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "Root disk size in GiB"
  type        = number
  default     = 20
}

variable "ssh_public_key_path" {
  description = "Public key installed on all instances for the ubuntu user"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Matching private key, written into the generated Ansible inventory"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH (22), the Kubernetes API (6443), NodePorts (30000-32767) and ICMP. Open to everyone by default; narrow it, e.g. [\"1.2.3.4/32\"], to restrict access"
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_cidrs must contain at least one valid IPv4 CIDR, e.g. \"1.2.3.4/32\"."
  }
}
