variable "ssh_public_key" {
  description = "Публичный OpenSSH-ключ для прямого SSH и Ansible. Не закрытый ключ."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[^ ]+) [A-Za-z0-9+/=]+", trimspace(var.ssh_public_key)))
    error_message = "Укажите содержимое публичного OpenSSH-ключа (.pub)."
  }
}

variable "ssh_user" {
  type        = string
  description = "Пользователь Ubuntu для SSH и Ansible."
  default     = "bdz"
  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{0,30}$", var.ssh_user)) && var.ssh_user != "root"
    error_message = "Нужен обычный Linux-пользователь, не root."
  }
}

variable "admin_cidr" {
  type        = string
  description = "Источники прямого SSH на все три ВМ. 0.0.0.0/0 разрешён пользователем."
  default     = "0.0.0.0/0"
  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "Укажите IPv4 CIDR."
  }
}

variable "image_name_pattern" {
  type        = string
  description = "Регулярное выражение для name/display_name образа Ubuntu 24.04; совпадение должно быть единственным."
  default     = "(?i)ubuntu.*24[._-]04"
}

variable "image_id" {
  type        = string
  description = "Необязательный ID выбранного Ubuntu 24.04, если в каталоге несколько совпадений."
  default     = null
}

variable "vm_cpu" {
  description = "Количество vCPU на каждой ВМ."
  type        = number
  default     = 2
  validation {
    condition     = var.vm_cpu >= 2 && floor(var.vm_cpu) == var.vm_cpu
    error_message = "Укажите целое число vCPU, не меньше 2."
  }
}

variable "vm_ram_gb" {
  description = "RAM на каждой ВМ в GB."
  type        = number
  default     = 8
  validation {
    condition     = var.vm_ram_gb >= 2 && floor(var.vm_ram_gb) == var.vm_ram_gb
    error_message = "Укажите целое количество GB RAM, не меньше 2."
  }
}

variable "flavor_name" {
  type        = string
  description = "Точное имя флейвора, если по CPU/RAM найдено несколько совпадений."
  default     = null
}

variable "disk_type_name" {
  type    = string
  default = "SSD"
}

variable "boot_disk_gb" {
  type    = number
  default = 60
}
