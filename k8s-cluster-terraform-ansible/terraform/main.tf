terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

locals {
  # Static, predictable private IPs: controllers 10.240.0.1x, workers 10.240.0.2x
  controller_ips = [for i in range(var.controller_count) : cidrhost(var.subnet_cidr, 10 + i)]
  worker_ips     = [for i in range(var.worker_count) : cidrhost(var.subnet_cidr, 20 + i)]
  # One /24 pod subnet per worker: 10.200.0.0/24, 10.200.1.0/24, ...
  worker_pod_cidrs = [for i in range(var.worker_count) : cidrsubnet(var.cluster_cidr, 8, i)]
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- Network ------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-subnet" }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.project_name}-rt" }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

# Pod network routes: traffic for 10.200.N.0/24 is sent to the ENI of worker-N.
# This replaces an overlay network (Flannel/Calico) with plain VPC routing.
resource "aws_route" "pod_cidr" {
  count = var.worker_count

  route_table_id         = aws_route_table.this.id
  destination_cidr_block = local.worker_pod_cidrs[count.index]
  network_interface_id   = aws_instance.worker[count.index].primary_network_interface_id
}

# --- Security -----------------------------------------------------------------

resource "aws_security_group" "cluster" {
  name        = "${var.project_name}-sg"
  description = "Kubernetes the hard way cluster nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "All traffic between nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "All traffic from pods"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.cluster_cidr]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "ICMP"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Kubernetes NodePort services"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

resource "aws_key_pair" "this" {
  key_name   = "${var.project_name}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# --- Instances ----------------------------------------------------------------

resource "aws_instance" "controller" {
  count = var.controller_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.controller_instance_type
  subnet_id              = aws_subnet.this.id
  private_ip             = local.controller_ips[count.index]
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.cluster.id]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name = "controller-${count.index}"
    Role = "controller"
  }
}

# Elastic IPs keep the controllers' public address stable, because that address
# is baked into the API server certificate and the remote admin kubeconfig.
resource "aws_eip" "controller" {
  count = var.controller_count

  domain   = "vpc"
  instance = aws_instance.controller[count.index].id

  tags = { Name = "controller-${count.index}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.this.id
  private_ip             = local.worker_ips[count.index]
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.cluster.id]

  # Workers forward packets for pod IPs that are not their own address.
  source_dest_check = false

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = "worker-${count.index}"
    Role    = "worker"
    PodCIDR = local.worker_pod_cidrs[count.index]
  }
}

# --- Ansible inventory --------------------------------------------------------

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.tftpl", {
    controllers = [for i, c in aws_instance.controller : {
      name       = "controller-${i}"
      public_ip  = aws_eip.controller[i].public_ip
      private_ip = c.private_ip
    }]
    workers = [for i, w in aws_instance.worker : {
      name       = "worker-${i}"
      public_ip  = w.public_ip
      private_ip = w.private_ip
      pod_cidr   = local.worker_pod_cidrs[i]
    }]
    ssh_private_key = pathexpand(var.ssh_private_key_path)
    cluster_cidr    = var.cluster_cidr
  })
}
