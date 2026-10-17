data "cloudru_evolution_compute_zone_collection" "available" {
  project_id = local.project_id
}

data "cloudru_evolution_compute_subnet_collection" "existing" {
  project_id = local.project_id
}

data "cloudru_evolution_compute_image_collection" "available" {
  project_id = local.project_id
}

data "cloudru_evolution_compute_flavor_collection" "available" {
  project_id = local.project_id
}

data "cloudru_evolution_compute_disk_type_collection" "available" {
  project_id = local.project_id
}

locals {
  image_candidates = [
    for image in data.cloudru_evolution_compute_image_collection.available.images : image
    if can(regex(var.image_name_pattern, "${image.name} ${image.display_name}"))
    && (var.image_id == null || image.id == var.image_id)
    && alltrue([
      for zone in keys(local.subnets) : contains([for z in image.zones : z.name if z.enabled], zone)
    ])
  ]
  flavor_candidates = [
    for flavor in data.cloudru_evolution_compute_flavor_collection.available.flavors : flavor
    if flavor.cpu == var.vm_cpu && flavor.ram == var.vm_ram_gb && flavor.gpu == 0
    && flavor.oversubscription == "1:1"
    && (var.flavor_name == null || flavor.name == var.flavor_name)
    && alltrue([
      for zone in keys(local.subnets) : contains([for z in flavor.zones : z.name if z.enabled], zone)
    ])
  ]
  disk_type_candidates = [
    for disk_type in data.cloudru_evolution_compute_disk_type_collection.available.disk_types : disk_type
    if upper(disk_type.name) == upper(var.disk_type_name)
    && alltrue([
      for zone in keys(local.subnets) : contains([for z in disk_type.zones : z.name if z.enabled], zone)
    ])
  ]

  # Не выбираем случайный первый образ или флейвор при неоднозначности.
  image     = try(one(local.image_candidates), null)
  flavor    = try(one(local.flavor_candidates), null)
  disk_type = try(one(local.disk_type_candidates), null)
}
