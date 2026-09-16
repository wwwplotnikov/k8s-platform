resource "cloudru_evolution_mk8s_node_pool" "workers" {
  cluster_id = cloudru_evolution_mk8s_cluster.main.id
  name       = "workers"
  version    = var.k8s_version

  machine_configuration = {
    flavor = {
      flavor_id = local.flavor_worker_id
    }
    disk = {
      type_name = local.disk_type
      size      = 50
    }
  }

  network_configuration = {
    nodes_subnet_id = cloudru_evolution_compute_subnet.nodes.id
  }

  scale_policy = {
    fixed_scale = {
      count = 2
    }
  }

  update_configuration = {
    strategy = "NODE_POOL_UPDATE_STRATEGY_ROLLING_UPDATE"
    rolling_update_policy = {
      max_surge       = 1
      max_unavailable = 0
    }
  }

  labels = {
    labels = {
      "workload" = "general"
    }
  }

  auto_repair = {
    enabled = true
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "40m"
  }
  lifecycle {
    ignore_changes = [timeouts]
  }
}

resource "cloudru_evolution_mk8s_node_pool" "database" {
  cluster_id = cloudru_evolution_mk8s_cluster.main.id
  name       = "database"
  version    = var.k8s_version

  machine_configuration = {
    flavor = {
      flavor_id = local.flavor_db_id
    }
    disk = {
      type_name = local.disk_type
      size      = 30
    }
  }

  network_configuration = {
    nodes_subnet_id = cloudru_evolution_compute_subnet.nodes.id
  }

  scale_policy = {
    fixed_scale = {
      count = 1
    }
  }

  update_configuration = {
    strategy = "NODE_POOL_UPDATE_STRATEGY_ROLLING_UPDATE"
    rolling_update_policy = {
      max_surge       = 1
      max_unavailable = 0
    }
  }

  labels = {
    labels = {
      "workload" = "database"
    }
  }

  taints = {
    taints = [{
      key    = "workload"
      value  = "database"
      effect = "EFFECT_NO_SCHEDULE"
    }]
  }

  auto_repair = {
    enabled = true
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "40m"
  }
  lifecycle {
    ignore_changes = [timeouts]
  }
}
