resource "cloudru_evolution_vpc_vpc" "main" {
  name        = "k8s-platform-vpc"
  project_id  = var.project_id
  description = "VPC for Kubernetes platform"

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
  lifecycle {
    ignore_changes = [timeouts]
  }
}

resource "cloudru_evolution_compute_subnet" "nodes" {
  project_id  = var.project_id
  name        = "k8s-nodes-subnet"
  description = "Subnet for Kubernetes nodes and control plane VIP"
  vpc_id      = cloudru_evolution_vpc_vpc.main.id

  default        = true
  routed_network = true

  zone = {
    name = local.zone_name
  }

  subnet_address  = "10.0.1.0/24"
  default_gateway = "10.0.1.1"

  dns_servers = {
    value = ["8.8.4.4", "8.8.8.8"]
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  lifecycle {
    ignore_changes = [timeouts]
  }
}

resource "cloudru_evolution_compute_nat_gateway" "main" {
  project_id  = var.project_id
  name        = "k8s-platform-snat"
  description = "Egress internet access for Kubernetes nodes (image pulls, ACME, upstream registries)"
  vpc_id      = cloudru_evolution_vpc_vpc.main.id

  zone = {
    name = local.zone_name
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "20m"
  }
  lifecycle {
    ignore_changes = [timeouts]
  }
}
