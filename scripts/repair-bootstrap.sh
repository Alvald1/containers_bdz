#!/usr/bin/env bash
# Однократное восстановление уже созданной ВМ; запускать от root через SSH.
set +x
set -euo pipefail
umask 077

if [[ $EUID -ne 0 ]]; then
  printf '%s\n' 'Запустите скрипт через sudo.' >&2
  exit 1
fi

script_dir=/var/lib/cloud/instance/scripts
script_count="$(find "$script_dir" -maxdepth 1 -type f -perm /111 | wc -l)"
if [[ "$script_count" -ne 1 || ! -x "$script_dir/runcmd" ]]; then
  printf '%s\n' 'Ожидался только один исполняемый пользовательский скрипт runcmd. Проверьте каталог scripts перед повторным запуском.' >&2
  exit 1
fi

recovery_dir="/var/log/bdz-bootstrap-recovery-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$recovery_dir"
cp -p /var/log/cloud-init.log /var/log/cloud-init-output.log \
  /var/lib/cloud/data/status.json /var/lib/cloud/data/result.json \
  "$script_dir/runcmd" "$recovery_dir/"
journalctl -b -u cloud-final.service --no-pager > "$recovery_dir/cloud-final.log"

cat > "$recovery_dir/recovery.yaml" <<'EOF'
#cloud-config
runcmd:
  - [sh, -c, "install -d -m 0755 /run/sshd && sshd -t && systemctl reload-or-restart ssh"]
EOF

cloud-init single --name runcmd --frequency always --file "$recovery_dir/recovery.yaml"
cloud-init single --name scripts_user --frequency always
sshd -t
systemctl is-active ssh.service

# Временный DNS до применения dns_servers в Terraform и обновления DHCP lease.
network_interface="$(ip -o -4 route show default | awk '{print $5; exit}')"
test -n "$network_interface"
resolvectl dns "$network_interface" 1.1.1.1
resolvectl default-route "$network_interface" yes
getent ahostsv4 archive.ubuntu.com > "$recovery_dir/dns-check.log"

apt-get -o APT::Update::Error-Mode=any update > "$recovery_dir/apt-update.log" 2>&1
apt-get install -y python3 ca-certificates curl > "$recovery_dir/apt-install.log" 2>&1

printf 'Исправленный runcmd и пакеты проверены. Исходные журналы: %s\n' "$recovery_dir"
printf '%s\n' 'История ошибки первого cloud-init сохранена; status/result.json не очищались.'
