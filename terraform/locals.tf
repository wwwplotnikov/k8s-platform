locals {
  zone = [
    for z in data.cloudru_evolution_compute_zone_collection.zones.zones :
    z if try(z.enabled, true)
  ][0]

  zone_id   = local.zone.id
  zone_name = local.zone.name

  disk_type = "SSD"

  # Control plane: 2 vCPU / 4 GB
  flavor_cp_id = [
    for f in data.cloudru_evolution_compute_flavor_collection.flavors.flavors :
    f.id if f.name == "gen-2-4"
  ][0]

  flavor_worker_id = [
    for f in data.cloudru_evolution_compute_flavor_collection.flavors.flavors :
    f.id if f.name == "gen-2-4"
  ][0]

  # Группа Database: 2 vCPU / 4 GB
  flavor_db_id = [
    for f in data.cloudru_evolution_compute_flavor_collection.flavors.flavors :
    f.id if f.name == "gen-2-4"
  ][0]
}
