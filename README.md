# Windows Software Orchestrator (pkg / arc / files)

Этот плейбук автоматизирует поиск, доставку и установку/удаление ПО на Windows‑хостах с трёмя режимами работы:

- **pkg** (умолчание, `exe/msi`) — установка/удаление через `win_package`.
- **arc** — распаковка архивов локально на контроллере и копирование содержимого на хост.
- **files** — копирование *шаблонов* (Jinja2) из `local_dir` на хост (c удалением при `state: absent`).

Плейбук также:
- собирает кастомные факты об установленном ПО (PowerShell‑скрипт),
- поддерживает удаление через произвольные `uninstall_string` из реестра,
- умеет работать напрямую из сетевой шары (`remote_source`) без копирования на хост,
- формирует единый отчёт об успехах по всем режимам и отправляет его в Telegram.

---

## Требования

- **Ansible**: 2.14+ (рекомендовано 2.15/2.16)
- **Коллекции** (см. `requirements.yaml`):
  - `ansible.windows`
  - `community.windows`
  - `community.general`
- **Windows‑хосты**: PowerShell 5.1+, WinRM настроен.
- **Контроллер**: доступ к каталогу `local_dir` (источник файлов и шаблонов).
- (Опционально) доступ к сетевой шару `remote_source` для пакетов EXE/MSI.

---

## Быстрый старт

```bash
ansible-galaxy collection install -r requirements.yaml

ansible-playbook -i hosts playbook.yml \
  -e dest='C:\Install' \
  -e local_dir='/source' \
  -e telegram_token='123:ABC' \
  -e telegram_chat_id='-1001234567890'
```

> Если вы хотите устанавливать EXE/MSI напрямую из сетевой шары:
> `-e remote_source='\\fileserver\share\autodownloads'`

---

## Переменные

| Переменная     | Тип          | Назначение                                                                                             |
|----------------|--------------|--------------------------------------------------------------------------------------------------------|
| `dest`         | string (Win) | Базовый каталог назначения на хосте Windows (обязательна).                                            |
| `local_dir`    | string (POSIX)| Базовый каталог на контроллере, где лежат исходные файлы/шаблоны.                                     |
| `remote_source`| string (Win) | Путь на **хосте** (обычно UNC), откуда `win_package` берёт EXE/MSI **напрямую** (без копирования).   |
| `patterns`     | list(dict)   | Описания устанавливаемых/копируемых объектов.                                                         |
| `patterns__*`  | list(dict)   | Части паттернов, которые мерджатся через `community.general.merge_variables` (см. ниже).              |
| `telegram_token` | string     | Токен бота Telegram (если нужен отчёт).                                                                |
| `telegram_chat_id` | string   | Чат/канал для отправки отчёта.                                                                         |

### Слияние паттернов

Плейбук объединяет переменные, начинающиеся с префикса `patterns__`, в один список `patterns_effective` при помощи фильтра
`community.general.merge_variables`. Это удобно для групп/хостов.

Пример:

```yaml
# group_vars/all.yml
patterns__base:
  - { regex: '7zip.*\.msi', mode: 'msi', args: ['/qn'], state: 'present' }

# host_vars/ws-01.yml
patterns__host:
  - { regex: 'TorBrowser.*\.zip', mode: 'arc', dest: 'C:\Tools\Tor', state: 'present' }
```

---

## Формат элементов `patterns`

Каждый элемент — это словарь с обязательным полем `regex` (регулярное выражение по имени файла из `local_dir`) и
набором параметров в зависимости от `mode`:

Общие поля:
- `regex` *(string, required)* — шаблон для поиска файлов в `local_dir` (регистронезависимый).
- `mode` *(string, optional)* — один из: `exe`/`msi` (**pkg**), `arc`, `files`. По умолчанию — `exe` (pkg‑ветка).
- `state` *(present|absent, optional)* — что сделать; по умолчанию `present`.
- `pre` *(string | list[string], optional)* — команды (на Windows‑хосте) выполнить **до** основного действия.
- `post` *(string | list[string], optional)* — команды (на Windows‑хосте) выполнить **после**.
- `force` *(bool, optional)* — игнорировать маркер `_installed` и выполнять снова.
- `dest` *(string, optional)* — базовый каталог назначения (для `arc` и `files`). Для `pkg` не требуется.

### Режим **pkg** (`exe`/`msi` — по умолчанию)

- `args` *(list[string], optional)* — аргументы тихой установки.
- `product_id` *(string, optional)* — **регекс по имени установленного приложения**. Используется при `state: absent`,
  если у записи в фактах `installed_software` отсутствует GUID и нужно выполнить `uninstall_string`.
- `creates_path` *(string, optional)* — путь, наличие которого подтверждает установку.
- `expected_return_code` *(list[int], optional, default: [0,3010])* — допустимые коды возврата.
- `wait_for_children` *(bool, default: true)* — ожидать дочерние процессы.
- **Источник**:  
  - если задан `remote_source` — пакет берётся как `{{ remote_source }}\{{ base }}` **без** предварительного копирования;  
  - иначе файл копируется в `{{ dest }}\{{ base }}` и оттуда запускается.

> При `state: absent` плейбук:
> 1) пытается удалить через `win_package` (если есть `product_id/GUID`),  
> 2) иначе ищет в кастомных фактах `installed_software` подходящую запись по имени (регекс `product_id`) и
>    запускает её `uninstall_string`. Для строк вида `MsiExec.exe /I{GUID}` автоматически преобразует в
>    `MsiExec.exe /X "{GUID}" /quiet /norestart`.

### Режим **arc**

- Распаковка архива локально на контроллере -> выборка файлов -> копирование на хост.
- `files` *(list[string], optional)* — если указан, копируются **только** перечисленные относительные пути из распакованного дерева; иначе — всё содержимое.
- `dest` *(string, optional)* — базовый каталог на хосте (по умолчанию `dest` из vars).
- При `state: absent`:
  - если `files` указан — удаляются перечисленные файлы в `dest`;
  - иначе — удаляется целевой каталог `dest`.

### Режим **files**

- `files` *(list[string], required)* — относительные пути в `local_dir`, которые копируются как **шаблоны** (`template`) на хост.
- `dest` *(string, optional)* — базовый каталог назначения (по умолчанию `dest`).
- При `state: absent` — удаляются соответствующие файлы из `dest`.
- Успешные наборы добавляются в `_files_success` и, далее, в общий `success_items`.

---

## Пример `patterns`

```yaml
patterns:
  # 1) PKG: 7-Zip MSI (установка)
  - regex: '(?i)^7z.*\.msi$'
    mode: msi
    args: ['/qn', 'ALLUSERS=1']
    creates_path: 'C:\Program Files\7-Zip\7z.exe'
    state: present

  # 2) PKG: Krita EXE (удаление по имени через uninstall_string)
  - regex: '(?i)^krita-x64-[\d.-]+-setup\.exe$'
    mode: exe
    product_id: '(?i)^Krita.*'     # поиск по имени в кастомных фактах
    state: absent

  # 3) ARC: распаковать TorBundle и скопировать только файлы torrc и bat
  - regex: '(?i)^TorBundle.*\.(zip|7z|rar|tgz|tar\.gz)$'
    mode: arc
    dest: 'C:\Program Files\TorBundle\tor'
    files:
      - 'torrc'
      - 'scripts\tor_install.bat'
    state: present

  # 4) FILES: скопировать конфиги как шаблоны
  - regex: '(?i)^torrc$'           # используется для выбора версии/билда (если есть)
    mode: files
    dest: 'C:\Program Files\TorBundle\tor'
    files:
      - 'torrc'
      - 'tor_install.bat'
    pre:
      - 'net stop Tor || exit /b 0'
    post:
      - '"C:\Program Files\TorBundle\tor\tor_install.bat"'
```

---

## Как это работает (flow)

1. **Сканирование `local_dir`** на контроллере и сопоставление файлов по `regex` из `patterns_effective`.
2. **Выбор версии**: для каждого паттерна берётся файл с максимальной версией, извлечённой из имени.
3. **Проверка маркеров**: ищутся `_installed` в `dest`, чтобы избежать повторной работы (кроме `force: true`).
4. **Формирование `planned_items`** и обогащение (`pkg_path` с учётом `remote_source`).
5. **pre‑команды** — выполняются на **всех режимах**.
6. **Выполнение по режимам**:
   - **arc** — распаковка локально → выбор файлов → копирование → маркеры/успех.
   - **pkg** — копирование (если нужно) → `win_package` → удаление исходников → маркеры/успех.
   - **files** — `template` копирование → маркеры/успех, либо удаление файлов при `absent`.
7. **Удаление (pkg/EXE) через `uninstall_string`** при необходимости (включая автозамены для `msiexec /I{GUID}`).
8. **post‑команды** — выполняются на **всех режимах**.
9. **Сбор отчёта**: агрегируются `_arc_success`, `pkg_success`, `_files_success` в `success_items` и суммируются в `success_total`.
10. **Telegram**: `telegram.yaml` отправляет HTML‑сообщение с итогами по каждому хосту.

---

## Кастомные факты: `installed_software`

В `pre_tasks` на хост помещается `C:\ProgramData\Ansible\facts.d\installed_software.ps1`, который собирает:
- `name`, `version`
- `uninstall_string` — строка деинсталляции
- `product_id` — GUID, если присутствует (иначе `null`)
- `registry_key` — ключ реестра источника

Эти факты используются, в частности, для удаления EXE по имени через `uninstall_string`.

---

## Работа с Defender

Плейбук может включать `defender.yaml` (через тег `defender`) для:
- разрешения уведомлений (toast),
- настройки Controlled Folder Access (CFA) и списка разрешённых приложений,
- моментального применения настроек.

Подключение:
```bash
ansible-playbook playbook.yml -t defender
```

---

## Telegram‑отчёт

Файл `telegram.yaml` формирует HTML‑сообщение и отправляет его в канал/чат.
Используются переменные:
- `telegram_token`
- `telegram_chat_id`

Плейбук агрегирует успехи всех режимов в `success_items`, так что в отчёт попадают **arc**, **pkg** и **files**.

---

## Маркеры `_installed` и идемпотентность

- Для **pkg/arc/files (present)** по завершении создаётся файл‑маркер: `{{ dest }}\{{ base }}_installed`.
- Для **absent** соответствующий маркер удаляется.
- Поле `force: true` принудительно запускает обработку даже при наличии маркера.

---

## Структура репозитория (рекомендуемая)

```
.
├─ playbook.yml                # этот плейбук
├─ requirements.yaml
├─ task_arc.yaml
├─ task_files.yaml
├─ defender.yaml               # опционально
├─ clear_markers.yml
├─ telegram.yaml
└─ source/                     # == local_dir (на контроллере)
   ├─ 7z2301-x64.msi
   ├─ TorBundle-13.0.tgz
   ├─ torrc
   └─ templates/...
```

---

## Отладка

Запускайте с тегом `debug` для промежуточных переменных:

```bash
IMAGE=quay.io/ansible/awx-ee:latest
SOURCE_DIR=/mnt/autodownloads
docker run --rm -it -v "$PWD"/win_soft_management:/work -v "${SOURCE_DIR}":/source -w /work -e "HOME=/work" ${IMAGE} ansible-playbook -i inventory.yaml $@
```

Ключевые отладочные переменные:
- `patterns_effective`, `install_items`, `planned_items[_prepared]`
- `_arc_success`, `pkg_results`, `_files_success`
- `success_items`, `success_total`

---

## Лицензия

MIT
