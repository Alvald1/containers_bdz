resource "cloudru_evolution_vpc_vpc" "bdz" {
  project_id  = local.project_id
  name        = local.prefix
  description = "MEPhI containers BDZ"

  lifecycle {
    precondition {
      condition = alltrue([
        for zone in keys(local.subnets) :
        contains([for z in data.cloudru_evolution_compute_zone_collection.available.zones : z.name if z.enabled], zone)
      ])
      error_message = "В mephi должны быть доступны ru.AZ-1, ru.AZ-2 и ru.AZ-3."
    }
    precondition {
      condition     = length(local.image_candidates) == 1
      error_message = "Нужен один доступный в трёх AZ образ Ubuntu 24.04. Уточните image_id/image_name_pattern. Совпадения: ${join(", ", [for i in local.image_candidates : "${i.id}: ${i.name}"])}."
    }
    precondition {
      condition     = length(local.flavor_candidates) == 1
      error_message = "Нужен один флейвор с выбранными CPU/RAM, GPU=0 и oversubscription=1:1. Уточните flavor_name. Совпадения: ${join(", ", [for f in local.flavor_candidates : f.name])}."
    }
    precondition {
      condition     = length(local.disk_type_candidates) == 1
      error_message = "Нужен один тип диска ${var.disk_type_name}, доступный во всех трёх AZ."
    }
  }
}

resource "cloudru_evolution_compute_subnet" "zone" {
  for_each       = local.subnets
  project_id     = local.project_id
  name           = "${local.prefix}-${lower(replace(each.key, ".", "-"))}"
  zone           = { name = each.key }
  vpc_id         = cloudru_evolution_vpc_vpc.bdz.id
  subnet_address = each.value
  routed_network = true
  dns_servers    = { value = ["1.1.1.1"] }
  # В mephi основная подсеть уже есть только в AZ-2. Фиксируем выбор,
  # чтобы после создания своих основных подсетей не переключать их обратно.
  default = contains(["ru.AZ-1", "ru.AZ-3"], each.key)

  lifecycle {
    precondition {
      condition = !contains(["ru.AZ-1", "ru.AZ-3"], each.key) || alltrue([
        for subnet in data.cloudru_evolution_compute_subnet_collection.existing.subnets :
        subnet.vpc_id == cloudru_evolution_vpc_vpc.bdz.id && subnet.name == "${local.prefix}-${lower(replace(each.key, ".", "-"))}"
        if subnet.default && subnet.zone.name == each.key
      ])
      error_message = "В ${each.key} уже есть другая основная подсеть. Проверьте её перед изменением default: автоматически переключать её на подсеть БДЗ нельзя."
    }
  }
}

resource "cloudru_evolution_compute_security_group" "node" {
  for_each   = local.nodes
  project_id = local.project_id
  name       = "${local.prefix}-${each.key}"
  zone       = { name = each.value.zone }
}

locals {
  swarm_ports = {
    management = { protocol = "IP_PROTOCOL_TCP", ports = "2377:2377" }
    gossip_tcp = { protocol = "IP_PROTOCOL_TCP", ports = "7946:7946" }
    gossip_udp = { protocol = "IP_PROTOCOL_UDP", ports = "7946:7946" }
    overlay    = { protocol = "IP_PROTOCOL_UDP", ports = "4789:4789" }
  }
  security_rules = merge(
    {
      for name in keys(local.nodes) : "${name}-egress" => {
        node = name, direction = "TRAFFIC_DIRECTION_EGRESS", protocol = "IP_PROTOCOL_ANY", ports = "any", cidr = "0.0.0.0/0"
      }
    },
    {
      for name in keys(local.nodes) : "${name}-ssh" => {
        node = name, direction = "TRAFFIC_DIRECTION_INGRESS", protocol = "IP_PROTOCOL_TCP", ports = "22:22", cidr = var.admin_cidr
      }
    },
    {
      for pair in setproduct(keys(local.nodes), keys(local.nodes), keys(local.swarm_ports)) :
      "${pair[0]}-from-${pair[1]}-${pair[2]}" => {
        node      = pair[0]
        direction = "TRAFFIC_DIRECTION_INGRESS"
        protocol  = local.swarm_ports[pair[2]].protocol
        ports     = local.swarm_ports[pair[2]].ports
        cidr      = "${local.nodes[pair[1]].private_ip}/32"
      } if pair[0] != pair[1]
    }
  )
}

resource "cloudru_evolution_compute_security_group_rule" "rule" {
  for_each          = local.security_rules
  security_group_id = cloudru_evolution_compute_security_group.node[each.value.node].id
  description       = each.key
  direction         = each.value.direction
  ether_type        = "ETHER_TYPE_IPV4"
  ip_protocol       = each.value.protocol
  port_range        = each.value.ports
  remote_ip_prefix  = each.value.cidr
}

resource "cloudru_evolution_compute_external_ip" "node" {
  for_each   = local.nodes
  project_id = local.project_id
  name       = "${local.prefix}-${each.key}"
  zone       = { name = each.value.zone }
}
