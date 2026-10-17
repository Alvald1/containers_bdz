#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$repo_dir/.tools:$PATH"
cd "$repo_dir/terraform"

: "${AUTH_KEY_ID:?Введите и экспортируйте AUTH_KEY_ID}"
: "${AUTH_SECRET:?Введите и экспортируйте AUTH_SECRET}"
export AWS_ACCESS_KEY_ID="ef1bdf96-f160-40b3-844a-7df532ca99b9:${AUTH_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="$AUTH_SECRET"
export AWS_DEFAULT_REGION='ru-central-1'
export AWS_PAGER=''
export TF_CLI_CONFIG_FILE="$repo_dir/terraform/terraformrc"
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN TF_LOG TF_LOG_PATH

terraform init -input=false -no-color
terraform validate -no-color

# Идентичность реестра берём из конфигурации, которую затем импортируем.
metadata="$(terraform console -no-color -var-file=mephi.tfvars <<<'jsonencode({project_id = local.project_id, name = local.registry_name})' |
  python3 -c 'import json,sys; print(json.load(sys.stdin))')"
project_id="$(printf '%s' "$metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin)["project_id"])')"
registry_id="$(printf '%s' "$metadata" | python3 "$repo_dir/scripts/ensure-registry.py")"

state_id="$(terraform show -json | python3 -c '
import json, sys
resources = json.load(sys.stdin).get("values", {}).get("root_module", {}).get("resources", [])
print(next((r["values"]["id"] for r in resources if r["address"] == "cloudru_evolution_artifact_registry_registry.bdz"), ""))
')"
if [[ -z "$state_id" ]]; then
  terraform import -input=false -no-color -var-file=mephi.tfvars \
    cloudru_evolution_artifact_registry_registry.bdz "$project_id:$registry_id"
elif [[ "$state_id" != "$registry_id" ]]; then
  printf '%s\n' 'В Terraform уже управляется другой registry. State не изменён; проверьте идентификаторы.' >&2
  exit 1
fi

# Обновляем outputs только если импортированный registry не требует изменений.
bash "$repo_dir/scripts/plan.sh" --registry
terraform show -json mephi.tfplan | python3 -c '
import json, sys
changes = [r["address"] for r in json.load(sys.stdin).get("resource_changes", [])
           if r["change"]["actions"] != ["no-op"]]
if changes:
    sys.exit("После импорта остались изменения ресурсов; apply остановлен: " + ", ".join(changes))
'
bash "$repo_dir/scripts/apply.sh"

inventory_tmp="$(mktemp "$repo_dir/ansible/.inventory.XXXXXX")"
trap 'rm -f "$inventory_tmp"' EXIT
terraform output -json ansible_inventory > "$inventory_tmp"
python3 -m json.tool "$inventory_tmp" >/dev/null
mv "$inventory_tmp" "$repo_dir/ansible/inventory.json"
trap - EXIT
printf 'Registry ACTIVE и импортирован: %s\nInventory обновлён.\n' "$registry_id"
