# Docker Swarm и GitLab CE через Ansible

Ansible настраивает три готовые ВМ Ubuntu 24.04 из Terraform: устанавливает
Docker, объединяет узлы в Swarm как Manager и разворачивает GitLab CE
с внешним PostgreSQL. Terraform отвечает за ВМ, сеть, firewall и учёт
импортированного Container Registry; Ansible — за настройку узлов, сборку
образа, деплой и проверки. Создание ВМ описано в [infra-plan.md](infra-plan.md), реестр — в
[`terraform/registry.tf`](../terraform/registry.tf).

## Состав и границы

| Компонент | Размещение и назначение |
|---|---|
| etcd | Три участника, по одному на каждом узле; кворум для Patroni |
| PostgreSQL + Patroni | По одному экземпляру на узел; один primary и два standby, автоматическое переключение primary |
| HAProxy | Три реплики; адрес `postgres:5432` в backend-сети ведёт на текущий primary по проверке Patroni `/primary` |
| Nginx | Три реплики, только frontend-сеть; входящий HTTP направляется в GitLab |
| GitLab CE | Одна реплика на `manager-1`, подключена к frontend и backend; встроенный PostgreSQL отключён, встроенный Redis используется |

Patroni использует `synchronous_mode`, `synchronous_mode_strict` и одну
синхронную реплику. Подтверждение записи ожидает репликацию; если подходящего
standby нет, записи блокируются. Переключение primary занимает время и требует
переподключения клиентов. Распределённая файловая система не используется:
PostgreSQL реплицирует данные между собственными локальными томами.
Репликация физическая: первоначальная копия через `pg_basebackup`, затем
передача WAL. Проверка контролирует два активных физических слота и работающий
WAL receiver на каждой standby, а также фактическое появление записанной строки.

Отказоустойчивость относится к PostgreSQL. Репозитории Gitaly, uploads,
конфигурация и остальные данные GitLab, включая Redis, остаются на локальном
диске `manager-1`. Потеря этого узла делает GitLab недоступным. Резервное
копирование, централизованный мониторинг и обновления без простоя в этот этап
не входят.

Параметры, готовые образы и адрес приложения находятся в
[`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml). Версии PostgreSQL
и Patroni закреплены в [Dockerfile](../ansible/roles/gitlab/files/postgres/Dockerfile).
Этот образ собирается на первом Manager с тегом, зависящим от содержимого
исходников. Ansible публикует его как
`<registry_endpoint>/postgres:<хеш_исходников>`, затем Swarm скачивает образ
из Cloud.ru Container Registry. Это единственный собственный образ: он
содержит PostgreSQL и Patroni. Готовые образы GitLab, Nginx и HAProxy берутся
из Docker Hub, etcd — из Quay.

При деплое Swarm разрешает тег в digest (`resolve_image: always`) и получает
данные авторизации для скачивания (`with_registry_auth: true`). Временный
Docker config создаётся на первом Manager в tmpfs `/dev/shm/bdz-registry`
и удаляется в `always`, в том числе при ошибке деплоя. Зависимости
управляющей машины закреплены в `ansible/requirements.txt` и
`ansible/requirements.yml`.

## Подготовка управляющей машины

Команды выполняются из корня репозитория. Нужны Python 3.12–3.14, Terraform
`>= 1.16.6, < 2.0.0` с уже инициализированным backend и SSH-ключ `~/.ssh/univ`.
Версия Terraform `1.16.6` указана в `.terraform-version`; рекомендуется
положить исполняемый файл в `.tools/terraform`. Скрипты выбирают его перед
системным Terraform из `PATH`. После перехода с 1.6.6 сохранённый Terraform-план
нужно построить заново, прежде чем запускать `apply`.
На ВМ используется
пользователь `bdz` с sudo. Ansible сохраняет известные SSH-ключи серверов
в локальном `ansible/known_hosts`; изменившийся ключ требует проверки.

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r ansible/requirements.txt
(
  cd ansible
  ../.venv/bin/ansible-galaxy collection install -r requirements.yml -p collections
)
```

## Развёртывание и проверка

На готовой инфраструктуре подготовьте приватный Docker Registry
`containers-bdz-7c2b32ba`, режим `LOCAL`, тариф `BASIC`, без автоматического
удаления образов. Из-за [ошибки провайдера Cloud.ru #43](https://github.com/cloud-ru/evo-terraform/issues/43)
первоначальное создание выполняется через API с последующим импортом:

Для bootstrap экспортируйте `AUTH_KEY_ID` / `AUTH_SECRET` аккаунта с доступом
к проекту, S3 state и ролями `ar.registry.editor` / `ar.registry.viewer`.
Полный Ansible-деплой для публикации образа использует `REGISTRY_USERNAME` /
`REGISTRY_PASSWORD`; если они не заданы, используются те же `AUTH_KEY_ID` /
`AUTH_SECRET`.

```bash
bash scripts/bootstrap-registry.sh
```

Bootstrap берёт проект и имя из Terraform-конфигурации, переиспользует
подходящий реестр либо создаёт его через API без `upstream` и `retentionPolicy`.
После проверки статуса `ACTIVE` импортирует его как `<project_id>:<registry_id>`.
Затем строит план только для реестра и допускает apply исключительно для
обновления outputs, если изменений ресурсов нет. Inventory обновляется
атомарно; дополнительно удалять его после bootstrap не нужно.
Output `container_registry` содержит endpoint, а `ansible_inventory`
передаёт его как `all.vars.registry_endpoint`.

Внутри bootstrap используется `plan.sh --registry` с target
`cloudru_evolution_artifact_registry_registry.bdz`. Это неполная проверка
инфраструктуры, позволяющая проверить импортированный реестр при недоступном
или неполном каталоге зон ВМ. Отдельный запуск после bootstrap не требуется.
Обычные операции с ВМ по-прежнему выполняются через Terraform plan/apply.

Для дальнейшего деплоя и проверки:

```bash
bash scripts/ansible.sh
ANSIBLE_PLAYBOOK=verify.yml bash scripts/ansible.sh
```

Проверка автоматического переключения временно останавливает текущий primary,
проверяет сохранность подтверждённой записи, запись на новом primary и
восстановление GitLab. В конце возвращает остановленный экземпляр и проверяет
три PostgreSQL-узла. Запускайте на учебном стенде с допустимым перерывом:

```bash
ANSIBLE_PLAYBOOK=failover.yml bash scripts/ansible.sh
```

Смена версий PostgreSQL/Patroni требует отдельного порядка обновления по одному
узлу с проверкой репликации. Общий `docker stack deploy` не гарантирует этот
порядок для трёх разных служб; его нельзя считать обновлением БД без простоя.

Повторный запуск использует сохранённый inventory, поэтому не обращается
к Terraform state. Полный деплой по-прежнему требует credentials реестра.
`verify.yml`, `bootstrap.yml` и `smoke.yml` с готовым inventory работают
без облачных credentials.

Если ВМ пересозданы, удалите `ansible/inventory.json` и повторите
`bash scripts/ansible.sh` с `AUTH_KEY_ID` / `AUTH_SECRET`: скрипт заново
прочитает Terraform output. Сам `ansible.sh` не выполняет Terraform apply.

Отдельная диагностика установки Docker/Swarm и тестового сервиса:

```bash
ANSIBLE_PLAYBOOK=bootstrap.yml bash scripts/ansible.sh
ANSIBLE_PLAYBOOK=smoke.yml bash scripts/ansible.sh
```

Аргументы скрипта передаются `ansible-playbook`, например
`bash scripts/ansible.sh --syntax-check`. Не ограничивайте запуск Swarm одним
узлом через `--limit`: при объединении требуется полный inventory трёх Manager.

Локальные тесты API-логики выполняются без облачных вызовов:

```bash
python3 -m unittest discover -s tests -v
```

Они проверяют повторный запуск, ожидание операции и обработку ошибок;
успех тестов не подтверждает создание реестра или импорт в реальном облаке.

## Доступ к GitLab

Облачный firewall сохраняет публичный вход только по SSH. Для HTTP и Git SSH
используется локальный туннель. Добавьте на своей машине строку в `/etc/hosts`:

```text
127.0.0.1 gitlab.bdz.test
```

Оставьте следующую команду работающей в отдельном терминале. Если ВМ
пересозданы, замените публичный IP на актуальный адрес из Terraform inventory.

```bash
ssh -i ~/.ssh/univ -N \
  -L 8080:127.0.0.1:8080 \
  -L 2222:127.0.0.1:2222 \
  bdz@37.230.192.222
```

Откройте [http://gitlab.bdz.test:8080](http://gitlab.bdz.test:8080). Имя
администратора — `root`. После добавления своего публичного SSH-ключа в GitLab
адрес репозитория имеет вид `ssh://git@gitlab.bdz.test:2222/group/project.git`.

## Секреты

Пароли передаются через Docker Secrets и читаются из `/run/secrets`, а не из
переменных окружения стека. Задачи с паролями и Swarm join-токенами используют
`no_log`. Секреты и локальный inventory не нужно добавлять в Git.

Чтобы получить первоначальный пароль `root`, выполните **в своём терминале**:

```bash
ssh -i ~/.ssh/univ bdz@37.230.192.222 \
  'sudo docker exec "$(sudo docker ps -q --filter label=com.docker.swarm.service.name=bdz_gitlab)" cat /run/secrets/gitlab_root_password'
```

Команда читает пароль из работающего контейнера на `manager-1`. Он применяется
при первоначальном создании пользователя; после смены пароля в GitLab значение
этого секрета не становится новым паролем автоматически.

## Проверено 17.10.2026

- BASIC Registry `containers-bdz-7c2b32ba.cr.cloud.ru` создан через API и
  импортирован в Terraform: `9f225d15-a991-4f79-9867-ba91f8df59e8`.
  Целевой план реестра после импорта — `No changes`.
- Полный `site.yml` завершился с `failed=0`, `unreachable=0` на всех трёх ВМ.
  Повторная настройка Docker/Swarm сохранила существующий кластер и секреты.
- На трёх узлах запущен здоровый образ
  `containers-bdz-7c2b32ba.cr.cloud.ru/postgres:71cf77d211f3`
  с одинаковым digest
  `sha256:e9a1f9c63f56362021b60211400e5c13a7d5bab0a076d456c06973d7b2866ef2`.
  Временный `/dev/shm/bdz-registry` после публикации удалён.
- После перехода на registry проверены один primary, две streaming standby,
  два активных физических replication slot, WAL receiver и доставка
  контрольной записи на обе реплики. GitLab readiness и страница входа
  возвращают HTTP 200 через каждый Manager.
- Отдельный тест `failover.yml` до перехода на registry подтвердил автоматическое
  переключение `postgres-3` → `postgres-1`, сохранность подтверждённой записи,
  новую запись и возврат остановленного узла как standby. Тестовые схемы удалены.
- Прямое TCP-соединение из Nginx к PostgreSQL на 5432 заблокировано;
  frontend подключён только к `frontend` и служебной сети `ingress`.

Эти проверки не подтверждают полную HA GitLab или обновление PostgreSQL без
простоя. Общий Terraform plan также нельзя считать проверенным: API каталога
зон возвращал две зоны вместо трёх, а для registry использовался отдельный target.

## Документация

- [Docker Swarm: секреты](https://docs.docker.com/engine/swarm/secrets/)
- [GitLab: внешний PostgreSQL](https://docs.gitlab.com/administration/postgresql/external/)
- [Patroni: режимы репликации и synchronous_mode_strict](https://patroni.readthedocs.io/en/latest/replication_modes.html)
- [Patroni: REST API и проверка /primary](https://patroni.readthedocs.io/en/latest/rest_api.html)
