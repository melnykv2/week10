# Optional. By default SSH, the Kubernetes API and NodePorts are open to everyone (0.0.0.0/0).
# To restrict access, copy this file to terraform.tfvars and list the allowed networks.
# Find your own IP with: curl -s https://checkip.amazonaws.com
admin_cidrs = [
  "91.223.227.46/32"
]
