#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$repo_dir/.venv/bin:$repo_dir/.tools:$PATH"
export ANSIBLE_CONFIG="$repo_dir/ansible/ansible.cfg"
cd "$repo_dir/ansible"

if ! command -v ansible-playbook >/dev/null; then
  printf '%s\n' 'Установите зависимости Ansible по README.md.' >&2
  exit 1
fi

if [[ ! -s inventory.json ]]; then
  inventory_tmp_dir="$(mktemp -d "$repo_dir/ansible/.inventory.XXXXXX")"
  trap 'rm -rf "$inventory_tmp_dir"' EXIT
  (
    : "${AUTH_KEY_ID:?Введите и экспортируйте AUTH_KEY_ID сервисного аккаунта bdz-terraform}"
    : "${AUTH_SECRET:?Введите и экспортируйте AUTH_SECRET сервисного аккаунта bdz-terraform}"

    export CLOUDRU_TENANT_ID='ef1bdf96-f160-40b3-844a-7df532ca99b9'
    export AWS_ACCESS_KEY_ID="${CLOUDRU_TENANT_ID}:${AUTH_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="$AUTH_SECRET"
    export AWS_DEFAULT_REGION='ru-central-1'
    export AWS_PAGER=''
    export TF_CLI_CONFIG_FILE="$repo_dir/terraform/terraformrc"
    unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN TF_LOG TF_LOG_PATH

    terraform -chdir="$repo_dir/terraform" output -json ansible_inventory > "$inventory_tmp_dir/inventory.json"
  )
  python3 -m json.tool "$inventory_tmp_dir/inventory.json" >/dev/null
  ansible-inventory -i "$inventory_tmp_dir/inventory.json" --list >/dev/null
  mv "$inventory_tmp_dir/inventory.json" inventory.json
  rmdir "$inventory_tmp_dir"
  trap - EXIT
else
  python3 -m json.tool inventory.json >/dev/null
  ansible-inventory --list >/dev/null
fi

mkdir -p .cache
ansible-playbook "${ANSIBLE_PLAYBOOK:-site.yml}" "$@" 2>&1 | tee .cache/ansible.log
