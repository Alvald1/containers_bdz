# БДЗ: GitLab CE в Docker Swarm

Terraform управляет тремя ВМ, сетью и импортированным Container Registry в Cloud.ru
Evolution. Ansible настраивает Docker Swarm, разворачивает GitLab CE
и PostgreSQL с репликацией и автоматическим переключением через Patroni,
etcd и HAProxy, затем проверяет сервисы.
Скрипт `plan.sh` только готовит план и не выполняет `apply`.

## Ansible: Docker Swarm, GitLab и PostgreSQL

На готовых ВМ сначала подготовьте приватный BASIC Registry. Из-за
[ошибки провайдера Cloud.ru #43](https://github.com/cloud-ru/evo-terraform/issues/43)
он создаётся через API и импортируется в Terraform одной командой
`scripts/bootstrap-registry.sh`. Скрипт ждёт `ACTIVE`, проверяет отсутствие
изменений ресурсов в плане, сохраняет outputs и обновляет inventory.

В терминале нужны `AUTH_KEY_ID` / `AUTH_SECRET` аккаунта с доступом к проекту,
S3 state и ролями `ar.registry.editor` / `ar.registry.viewer`. Для публикации
образа полный Ansible-деплой использует `REGISTRY_USERNAME` /
`REGISTRY_PASSWORD`; если они не заданы, используются те же `AUTH_KEY_ID` /
`AUTH_SECRET`.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r ansible/requirements.txt
(cd ansible && ../.venv/bin/ansible-galaxy collection install -r requirements.yml -p collections)
bash scripts/bootstrap-registry.sh
bash scripts/ansible.sh
```

Ansible собирает собственный образ PostgreSQL с Patroni на первом Manager
и публикует его в Registry; остальные узлы скачивают этот образ оттуда.
Готовые образы остальных компонентов остаются в Docker Hub и Quay.
Повторный деплой использует сохранённый inventory, но требует credentials
реестра. Проверки с готовым inventory обходятся без облачных credentials:

```sh
ANSIBLE_PLAYBOOK=verify.yml bash scripts/ansible.sh
```

Подготовка, доступ через SSH-туннель и проверка переключения описаны в
[инструкции Ansible](docs/ansible.md).
Данные PostgreSQL реплицируются; Git-репозитории и остальные файлы GitLab
пока хранятся на `manager-1`. Это не полная HA-конфигурация GitLab.

## Инфраструктура

- Проект `mephi`: `7c2b32ba-0194-445b-afc3-a406a4f0171e`.
- S3 tenant: `ef1bdf96-f160-40b3-844a-7df532ca99b9`.
- Backend: существующий приватный бакет `containers-bdz-tfstate`.
- Три будущих Swarm Manager: по одной ВМ в `ru.AZ-1`, `ru.AZ-2`, `ru.AZ-3`.
- У каждой ВМ свой публичный IP для прямого SSH и исходящего доступа.
- Одна VPC и три приватные подсети для связи между узлами Swarm.
- По умолчанию каждая ВМ: 2 vCPU, 8 GB RAM, SSD 60 GB.

Прямой SSH на порт 22 каждой ВМ разрешён с любого IPv4 по согласованной
настройке `admin_cidr = "0.0.0.0/0"`. Порты Swarm — TCP 2377, TCP/UDP 7946,
UDP 4789 — доступны только между приватными IP менеджеров.
Остальные входящие подключения запрещены.

cloud-init создаёт пользователя, добавляет публичный SSH-ключ и выполняет
базовую настройку Ubuntu 24.04. Паролей, закрытых ключей и join-токенов в нём нет.

## Подготовка и plan

Нужны Terraform `>= 1.16.6, < 2.0.0`, Bash и ключ сервисного аккаунта с доступом
к проекту и бакету. Рекомендуемая версия `1.16.6` указана в `.terraform-version`.
Провайдер `cloudru/cloud` закреплён на версии 2.1.5;
`terraform/terraformrc` используется скриптом для его установки.

Рекомендуется хранить исполняемый файл Terraform локально в `.tools/terraform`.
Скрипты `plan.sh`, `apply.sh`, `bootstrap-registry.sh` и `ansible.sh` выбирают его перед системной
версией из `PATH`. Без локального файла нужна подходящая версия в `PATH`.
Для прямого запуска Terraform из корня проекта:

```sh
export PATH="$PWD/.tools:$PATH"
terraform version
```

Terraform 1.6.6 аварийно завершался при применении плана Registry с ошибкой
`unexpected checkable object` для `var.ssh_user`. После смены версии обязательно
постройте план заново через `scripts/plan.sh` или `scripts/plan.sh --registry`:
сохранённый план от 1.6.6 несовместим с новой версией. Успешный `validate`
на новой версии сам по себе не подтверждает успешный облачный `apply`.

Из корня репозитория создайте локальный файл параметров:

```sh
cp -n terraform/mephi.tfvars.example terraform/mephi.tfvars
nano terraform/mephi.tfvars
```

Вставьте **публичный** SSH-ключ в `ssh_public_key`. Пользователь для прямого
SSH задаётся через `ssh_user`, по умолчанию `bdz`.

Основные параметры всех трёх ВМ:

| Параметр | По умолчанию |
| --- | --- |
| `vm_cpu` | `2` |
| `vm_ram_gb` | `8` |
| `flavor_name` | `null`, подбор размера из каталога |
| `disk_type_name` | `"SSD"` |
| `boot_disk_gb` | `60` |
| `admin_cidr` | `"0.0.0.0/0"` |

Образ Ubuntu 24.04 выбирается из каталога; если найдено
несколько подходящих образов, задайте `image_id` или уточните `image_name_pattern`.
`terraform/mephi.tfvars` исключён из Git.

В том же локальном терминале с zsh введите ключи без отображения на экране:

```zsh
set +x
read -rs 'AUTH_KEY_ID?Key ID: '
printf '\n'
read -rs 'AUTH_SECRET?Secret: '
printf '\n'
export AUTH_KEY_ID AUTH_SECRET
```

Ключи остаются в окружении этого терминала. Записывать их в README, tfvars
или Terraform-конфигурацию не нужно. Скрипт сам формирует S3 credentials
с указанным выше tenant проекта `mephi`.

```sh
bash scripts/plan.sh
```

Отдельно проверить уже импортированный Container Registry можно командой:

```sh
bash scripts/plan.sh --registry
```

Это фиксированный target `cloudru_evolution_artifact_registry_registry.bdz`;
он не проверяет всю инфраструктуру. Такой план используется внутри
`bootstrap-registry.sh`, поэтому после bootstrap отдельно запускать его
не требуется. Он также полезен, если каталог зон недоступен или возвращает
неполный список и блокирует полный план. Для первоначального создания BASIC
Registry используйте только `bootstrap-registry.sh`. Запуск `plan.sh` без
`--registry` сохраняет полный охват для работы с ВМ и остальной инфраструктурой.

Скрипт выполняет `init`, `validate` и `plan`. Результаты:

- `terraform/mephi.tfplan` — сохранённый план;
- `terraform/mephi.tfplan.txt` — его текст для просмотра.

При ошибке команды `terraform plan` файл `mephi.tfplan` удаляется;
применить предыдущий сохранённый план после этой ошибки нельзя.

```sh
less terraform/mephi.tfplan.txt
```

После работы можно убрать ключи из окружения:

```sh
unset AUTH_KEY_ID AUTH_SECRET
```

## Создание ВМ по проверенному плану

После просмотра плана и решения создать ресурсы, в том же терминале с
`AUTH_KEY_ID` и `AUTH_SECRET`:

```sh
bash scripts/apply.sh
```

Скрипт применяет сохранённый `terraform/mephi.tfplan` и создаёт платные ресурсы.
Повторного интерактивного подтверждения для сохранённого плана Terraform нет.
Результат сохраняется в `terraform/mephi.apply.log`, который исключён из Git.
Не запускайте несколько операций с этим state одновременно.

Если apply завершился частично, сначала снова выполните `bash scripts/plan.sh`:
он прочитает remote state и построит план оставшейся работы. Проверьте изменения
перед повторным `bash scripts/apply.sh`; старый сохранённый план не используйте.

Для согласованной пары SSH используется публичный `~/.ssh/univ.pub`, а при
подключении — приватный `~/.ssh/univ`. Приватный ключ в Terraform не передаётся:

```sh
ssh -i ~/.ssh/univ -o IdentitiesOnly=yes bdz@PUBLIC_IP
```

`PUBLIC_IP` нужно взять из output `nodes` после успешного создания.

## Границы проверки

Локальная проверка логики создания реестра:

```sh
python3 -m unittest discover -s tests -v
```

Тесты заменяют HTTP-вызовы контролируемыми ответами. Их успех не подтверждает
создание реестра, импорт или доступ к облаку.

S3 backend настроен без блокировки state и используется одним оператором.
Обновление Terraform не включает блокировку автоматически. До параллельной
работы нужно отдельно настроить и проверить механизм блокировки.

`validate` и `plan` не доказывают работоспособность cloud-init, сети или сервисов.
Выбранный размер также не подтверждает непрерываемость ВМ: в схеме провайдера нет
параметра `preemptible`. Доступность выбранных образов и размеров, квоты,
стоимость и свойства ВМ проверяются перед разрешённым развёртыванием.
Размеры по умолчанию — исходные параметры инфраструктуры, а не подтверждённый
расчёт ресурсов для GitLab.

Детали решений и ссылки на документацию — в [плане инфраструктуры](docs/infra-plan.md).
