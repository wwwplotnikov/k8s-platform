data "cloudru_evolution_compute_zone_collection" "zones" {
  project_id = var.project_id
}

data "cloudru_evolution_compute_flavor_collection" "flavors" {
  project_id = var.project_id
}

data "cloudru_evolution_compute_disk_type_collection" "disk_types" {
  project_id = var.project_id
}
data "cloudru_evolution_mk8s_product_configuration_collection" "mk8s" {
  project_id = var.project_id
}
