output "picked_zone" {
  value = local.zone_name
}

output "picked_flavors" {
  value = {
    control_plane = local.flavor_cp_id
    worker        = local.flavor_worker_id
  }
}
data "cloudru_evolution_mk8s_kube_config_collection" "main" {
  cluster_id = cloudru_evolution_mk8s_cluster.main.id

  depends_on = [
    cloudru_evolution_mk8s_node_pool.workers,
    cloudru_evolution_mk8s_node_pool.database,
  ]
}

output "cluster_id" {
  value = cloudru_evolution_mk8s_cluster.main.id
}

output "vpc_id" {
  value = cloudru_evolution_vpc_vpc.main.id
}

output "nodes_subnet_id" {
  value = cloudru_evolution_compute_subnet.nodes.id
}

output "cp_endpoints" {
  value = cloudru_evolution_mk8s_cluster.main.network_configuration.cp_endpoints
}

output "kubeconfig" {
  value     = base64decode(data.cloudru_evolution_mk8s_kube_config_collection.main.kube_config.config)
  sensitive = true
}
output "available_k8s_versions" {
  value = {
    for c in data.cloudru_evolution_mk8s_product_configuration_collection.mk8s.product_configuration.channels :
    c.channel => c.available_versions
  }
}

output "default_disk_type" {
  value = data.cloudru_evolution_mk8s_product_configuration_collection.mk8s.product_configuration.default_disk_type
}
output "snat_external_ip" {
  value = cloudru_evolution_compute_nat_gateway.main.external_ip.ip_address
}
