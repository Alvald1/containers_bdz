#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir/terraform"

if [[ ! -s mephi.tfvars ]]; then
  printf '%s\n' 'Скопируйте terraform/mephi.tfvars.example в terraform/mephi.tfvars и укажите публичный SSH-ключ.' >&2
  exit 1
fi

: "${AUTH_KEY_ID:?Введите и экспортируйте AUTH_KEY_ID сервисного аккаунта bdz-terraform}"
: "${AUTH_SECRET:?Введите и экспортируйте AUTH_SECRET сервисного аккаунта bdz-terraform}"

export CLOUDRU_PROJECT_ID='7c2b32ba-0194-445b-afc3-a406a4f0171e'
export CLOUDRU_TENANT_ID='ef1bdf96-f160-40b3-844a-7df532ca99b9'
export AWS_ACCESS_KEY_ID="${CLOUDRU_TENANT_ID}:${AUTH_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="$AUTH_SECRET"
export AWS_DEFAULT_REGION='ru-central-1'
export AWS_PAGER=''
export TF_CLI_CONFIG_FILE="$repo_dir/terraform/terraformrc"
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN TF_LOG TF_LOG_PATH

terraform init -input=false -no-color
terraform fmt -check
terraform validate -no-color
terraform plan -input=false -no-color -var-file=mephi.tfvars -out=mephi.tfplan | tee mephi.tfplan.txt
