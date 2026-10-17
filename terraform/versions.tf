terraform {
  required_version = ">= 1.6.6, < 2.0.0"

  required_providers {
    cloudru = {
      source  = "cloudru/cloud"
      version = "2.1.5"
    }
  }

  backend "s3" {
    bucket = "containers-bdz-tfstate"
    key    = "mephi/infrastructure.tfstate"
    region = "ru-central-1"
    endpoints = {
      s3 = "https://s3.cloud.ru"
    }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
