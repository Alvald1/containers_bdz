resource "cloudru_evolution_compute_disk" "boot" {
  for_each   = local.nodes
  project_id = local.project_id
  name       = "${local.prefix}-${each.key}-boot"
  zone       = { name = each.value.zone }
  size       = var.boot_disk_gb
  bootable   = true
  shared     = false
  readonly   = false
  disk_type  = { id = try(local.disk_type.id, null) }
  image      = { id = try(local.image.id, null) }

  depends_on = [cloudru_evolution_vpc_vpc.bdz]

  lifecycle {
    precondition {
      condition     = try(var.boot_disk_gb >= max(local.image.min_disk, local.disk_type.min_size) && var.boot_disk_gb <= local.disk_type.max_size, false)
      error_message = "Размер загрузочного диска ${each.key} должен удовлетворять ограничениям образа и типа диска."
    }
  }
}

resource "cloudru_evolution_compute_interface" "node" {
  for_each                   = local.nodes
  project_id                 = local.project_id
  name                       = "${local.prefix}-${each.key}"
  zone                       = { name = each.value.zone }
  subnet                     = { id = cloudru_evolution_compute_subnet.zone[each.value.zone].id }
  ip_address                 = each.value.private_ip
  interface_security_enabled = true
  type                       = "INTERFACE_TYPE_REGULAR"
  security_groups            = [{ id = cloudru_evolution_compute_security_group.node[each.key].id }]
  attach_external_ip         = { id = cloudru_evolution_compute_external_ip.node[each.key].id }
}

resource "cloudru_evolution_compute_vm" "node" {
  for_each           = local.nodes
  project_id         = local.project_id
  name               = "${local.prefix}-${each.key}"
  description        = "MEPhI BDZ: Swarm manager"
  zone               = { name = each.value.zone }
  flavor             = { id = try(local.flavor.id, null) }
  disks              = [{ id = cloudru_evolution_compute_disk.boot[each.key].id }]
  network_interfaces = [{ id = cloudru_evolution_compute_interface.node[each.key].id }]

  cloud_init_userdata = base64encode("#cloud-config\n${yamlencode({
    hostname         = "${local.prefix}-${each.key}"
    manage_etc_hosts = true
    ssh_pwauth       = false
    disable_root     = true
    package_update   = true
    packages         = ["python3", "ca-certificates", "curl"]
    users = [{
      name                = var.ssh_user
      shell               = "/bin/bash"
      groups              = ["sudo"]
      sudo                = "ALL=(ALL) NOPASSWD:ALL"
      lock_passwd         = true
      ssh_authorized_keys = [trimspace(var.ssh_public_key)]
    }]
    write_files = [{
      path        = "/etc/ssh/sshd_config.d/00-bdz.conf"
      owner       = "root:root"
      permissions = "0644"
      content     = "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n"
    }]
    runcmd = [["sh", "-c", "sshd -t && systemctl reload ssh"]]
  })}")

  depends_on = [
    cloudru_evolution_compute_security_group_rule.rule,
  ]

  lifecycle {
    precondition {
      condition     = try(var.vm_cpu >= local.image.min_cpu && var.vm_ram_gb >= local.image.min_ram, false)
      error_message = "Размер ВМ не удовлетворяет требованиям выбранного образа."
    }
  }
}
