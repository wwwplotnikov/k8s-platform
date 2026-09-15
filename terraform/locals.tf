locals {
  zone = [
    for z in data.cloudru_evolution_compute_zone_collection.zones.zones :
    z if try(z.enabled, true)
  ][0]

  zone_id   = local.zone.id
  zone_name = local.zone.name

  flavor_cp_id = [
    for f in data.cloudru_evolution_compute_flavor_collection.flavors.flavors :
    f.id if f.cpu == 2 && f.ram == 4 && try(f.gpu, 0) == 0
  ][0]

  flavor_worker_id = [
    for f in data.cloudru_evolution_compute_flavor_collection.flavors.flavors :
    f.id if f.cpu == 4 && f.ram == 8 && try(f.gpu, 0) == 0
  ][0]

  disk_type = "SSD"

  flavor_db_id = [
    for f in data.cloudru_evolution_compute_flavor_collection.flavors.flavors :
    f.id if f.cpu == 2 && f.ram == 4 && try(f.gpu, 0) == 0
  ][0]
}
