resource "cloudru_evolution_mk8s_cluster" "main" {
  name       = "k8s-platform"
  project_id = var.project_id

  control_plane = {
    zones   = [local.zone_id]
    count   = 1
    version = var.k8s_version

    machine_configuration = {
      flavor = {
        flavor_id = local.flavor_cp_id
      }
    }
  }

  network_configuration = {
    services_subnet_cidr  = "10.96.0.0/12"
    pods_subnet_cidr      = "10.1.0.0/16"
    kube_api_internet     = true
    private_vip_subnet_id = cloudru_evolution_compute_subnet.nodes.id

    network_plugin = {
      calico = {
        enabled     = true
        app_version = "v3.31.4"
      }
    }
  }

  identity_configuration = {
    cluster_sa_id = var.cluster_sa_id
  }

  bootstrap_managed_addons = {
    coredns                    = { enabled = true }
    kube_proxy                 = { enabled = true }
    horizontal_pod_autoscaling = { enabled = true }
    persistent_disk_csi_driver = { enabled = true }
  }

  release_channel = "RELEASE_CHANNEL_STABLE"

  timeouts {
    create = "60m"
    update = "60m"
    delete = "40m"
  }

  lifecycle {
    ignore_changes = [timeouts]
  }
}
