provider "cloudru" {
  project_id = local.project_id
  # AUTH_KEY_ID и AUTH_SECRET читает провайдер из окружения.
}

locals {
  project_id = "7c2b32ba-0194-445b-afc3-a406a4f0171e"
  prefix     = "containers-bdz"
  subnets = {
    "ru.AZ-1" = "10.42.10.0/24"
    "ru.AZ-2" = "10.42.20.0/24"
    "ru.AZ-3" = "10.42.30.0/24"
  }
  nodes = {
    for index, zone in sort(keys(local.subnets)) : "manager-${index + 1}" => {
      zone       = zone
      private_ip = cidrhost(local.subnets[zone], 11)
    }
  }
}
