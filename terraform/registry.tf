locals {
  registry_name = "containers-bdz-7c2b32ba"
}

# BASIC создаётся scripts/bootstrap-registry.sh и импортируется из-за бага:
# https://github.com/cloud-ru/evo-terraform/issues/43
resource "cloudru_evolution_artifact_registry_registry" "bdz" {
  project_id                  = local.project_id
  name                        = local.registry_name
  registry_type               = "DOCKER"
  registry_mode               = "REGISTRY_MODE_LOCAL"
  tariff                      = "BASIC"
  is_public                   = false
  retention_policy_is_enabled = false
}
