#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir/terraform"

if [[ ! -s mephi.tfplan ]]; then
  printf '%s\n' 'Нет сохранённого плана terraform/mephi.tfplan. Сначала выполните scripts/plan.sh и проверьте результат.' >&2
  exit 1
fi

: "${AUTH_KEY_ID:?Введите и экспортируйте AUTH_KEY_ID сервисного аккаунта bdz-terraform}"
: "${AUTH_SECRET:?Введите и экспортируйте AUTH_SECRET сервисного аккаунта bdz-terraform}"

export AWS_ACCESS_KEY_ID="ef1bdf96-f160-40b3-844a-7df532ca99b9:${AUTH_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="$AUTH_SECRET"
export AWS_DEFAULT_REGION='ru-central-1'
export AWS_PAGER=''
export TF_CLI_CONFIG_FILE="$repo_dir/terraform/terraformrc"
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN TF_LOG TF_LOG_PATH

terraform apply -input=false -no-color mephi.tfplan 2>&1 | tee mephi.apply.log
