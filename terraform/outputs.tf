output "selected_catalog" {
  description = "Выбранные реальные параметры каталога: проверить перед apply."
  value = {
    image = { id = try(local.image.id, null), name = try(local.image.name, null) }
    flavor = {
      id = try(local.flavor.id, null), name = try(local.flavor.name, null), type = try(local.flavor.type, null), cpu = try(local.flavor.cpu, null), ram_gb = try(local.flavor.ram, null), oversubscription = try(local.flavor.oversubscription, null)
    }
    disk_type = { id = try(local.disk_type.id, null), name = try(local.disk_type.name, null) }
  }
}

output "nodes" {
  value = {
    for name, node in local.nodes : name => {
      id         = cloudru_evolution_compute_vm.node[name].id
      zone       = node.zone
      private_ip = node.private_ip
      public_ip  = cloudru_evolution_compute_external_ip.node[name].ip_address
      ssh        = "ssh ${var.ssh_user}@${cloudru_evolution_compute_external_ip.node[name].ip_address}"
    }
  }
}

output "ansible_inventory" {
  description = "JSON inventory для следующего этапа Ansible через прямой SSH."
  value = {
    all = {
      vars = {
        ansible_user      = var.ssh_user
        registry_endpoint = "${cloudru_evolution_artifact_registry_registry.bdz.name}.cr.cloud.ru"
      }
      children = {
        swarm_managers = {
          hosts = {
            for name, node in local.nodes : name => {
              ansible_host       = cloudru_evolution_compute_external_ip.node[name].ip_address
              swarm_advertise_ip = node.private_ip
            }
          }
        }
      }
    }
  }
}

output "container_registry" {
  description = "Приватный Docker Registry для образов БДЗ. Ключи доступа не входят в output."
  value = {
    id       = cloudru_evolution_artifact_registry_registry.bdz.id
    endpoint = "${cloudru_evolution_artifact_registry_registry.bdz.name}.cr.cloud.ru"
  }
}

output "ssh_config" {
  value = join("\n", [
    for name in keys(local.nodes) :
    "Host bdz-${name}\n  HostName ${cloudru_evolution_compute_external_ip.node[name].ip_address}\n  User ${var.ssh_user}\n  ForwardAgent no\n"
  ])
}
