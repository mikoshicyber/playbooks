# Windows Software Orchestrator (pkg / arc / files)

Этот плейбук автоматизирует поиск, доставку и установку/удаление ПО на Windows‑хостах с тремя режимами работы:

- **pkg** (умолчание, `exe/msi`) — установка/удаление через `win_package`.
- **arc** — распаковка архивов **локально в контейнере** и копирование содержимого на хост.
- **files** — копирование *шаблонов* (Jinja2) из `local_dir` на хост (c удалением при `state: absent`).

Плейбук также:
- собирает кастомные факты об установленном ПО (PowerShell‑скрипт),
- поддерживает удаление через произвольные `uninstall_string` из реестра (в т.ч. автозамена `MsiExec /I{GUID}` → `/X "{GUID}" /quiet /norestart`),
- умеет брать EXE/MSI **напрямую** с UNC‑шары (`remote_source`) без копирования,
- формирует единый отчёт об успехах по всем режимам и отправляет его в Telegram.

---

## Запуск в Docker

Рекомендуемый способ — через скрипт `run.sh`:

```bash
#!/bin/bash
IMAGE=quay.io/ansible/awx-ee:latest
SOURCE_DIR=/mnt/autodownloads
# пример пинга:  docker run --rm -it -v "$PWD":/work -w /work ${IMAGE} ansible -i inventory.yaml -m ping all -o
# установка коллекций: docker run --rm -it -v "$PWD":/work -w /work -e "HOME=/work" ${IMAGE} ansible-galaxy collection install -r requirements.yaml -p .ansible/collections
docker run --rm -it \
  -v "$PWD"/win_soft_management:/work \
  -v "${SOURCE_DIR}":/source \
  -w /work \
  -e "HOME=/work" \
  ${IMAGE} ansible-playbook -i inventory.yaml "$@"
```

> **Важно:**  
> * Монтирование `-v "${SOURCE_DIR}":/source` задаёт каталог источников внутри контейнера. Укажите реальный путь со стороны хоста Docker.  
> * Внутри контейнера плейбук ожидает `local_dir: "/source"`.  
> * `HOME=/work` нужно, чтобы коллекции и кэш Ansible писались в каталог проекта.

### Быстрый старт (Docker)

1) Установить коллекции (однократно):
```bash
docker run --rm -it -v "$PWD"/win_soft_management:/work -w /work -e HOME=/work \
  quay.io/ansible/awx-ee:latest ansible-galaxy collection install -r requirements.yaml -p .ansible/collections
```

2) Запустить плейбук:
```bash
./run.sh playbook.yml \
  -e dest='C:\Install' \
  -e local_dir='/source' \
  -e telegram_token='123:ABC' \
  -e telegram_chat_id='-1001234567890'
```

3) (Опционально) Использовать UNC‑источник на целевом хосте для EXE/MSI:
```bash
./run.sh playbook.yml \
  -e dest='C:\Install' \
  -e local_dir='/source' \
  -e remote_source='\\\\fileserver\\share\\autodownloads'
```

> В YAML экранируйте обратные слэши в строках Windows/UNC.

---

## Требования

- **Контейнер**: `quay.io/ansible/awx-ee:latest` (или совместимый EE‑образ с ansible‑core 2.14+).  
- **Коллекции** (см. `requirements.yaml`):
  - `ansible.windows`
  - `community.windows`
  - `community.general`
- **Windows‑хосты**: WinRM доступен; PowerShell 5.1+.
- **Контроллер (контейнер)**: доступ к каталогу с исходниками, смонтированному в `/source`.

---

## Переменные

| Переменная        | Тип             | Назначение                                                                                              |
|-------------------|-----------------|---------------------------------------------------------------------------------------------------------|
| `dest`            | string (Win)    | Базовый каталог назначения на хосте Windows (обязательна).                                             |
| `local_dir`       | string (POSIX)  | Базовый каталог **в контейнере**, где лежат исходные файлы/шаблоны (обычно `/source`).                 |
| `remote_source`   | string (Win)    | Путь на **хосте** (обычно UNC), откуда `win_package` берёт EXE/MSI **напрямую** (без копирования).    |
| `patterns`        | list(dict)      | Описания устанавливаемых/копируемых объектов.                                                          |
| `patterns__*`     | list(dict)      | Части паттернов, которые мерджатся в единый список.                                                    |
| `telegram_token`  | string          | Токен бота Telegram (если нужен отчёт).                                                                 |
| `telegram_chat_id`| string          | Чат/канал для отправки отчёта.                                                                          |

### Формат `patterns` (кратко)

Общее:
- `regex` *(required)* — выбор файла(ов) из `local_dir` (регистронезависимо).
- `mode` — `exe|msi` (ветка **pkg** по умолчанию), `arc`, `files`.
- `state` — `present|absent` (по умолчанию `present`).
- `pre` / `post` — команды на целевом Windows‑хосте (выполняются для всех режимов).
- `dest` — базовый путь назначения (для `arc`/`files`).

**pkg**: `args`, `product_id` (регекс по *имени* приложения для удаления через `uninstall_string`), `creates_path`, `expected_return_code` и т.д.  
**arc**: локальная распаковка в контейнере → выборка `files` → копирование в `dest`; при `absent` удаляются `files` или весь `dest`.  
**files**: копирование указанных `files` из `local_dir` в `dest` как шаблонов (`template`); при `absent` — удаление этих путей.

Полный пример см. в `playbook.yml`.

# Структура словаря `patterns` (и связанных переменных)

Этот раздел описывает входные данные плейбука — формат переменных и элементов списка `patterns`.

---

## Глобальные переменные

- **`dest`** *(string, Windows path, required)* — базовая папка назначения на целевом хосте.
- **`local_dir`** *(string, POSIX path, required)* — каталог на контроллере (или примонтированный в контейнер), в котором ищутся исходные файлы/шаблоны.
- **`remote_source`** *(string, Windows path/UNC, optional)* — путь на **хосте**, откуда запускать `exe/msi` **без копирования** (используется только для режима pkg). Если задан — копирование на хост пропускается, а путь пакета строится как `"{{ remote_source }}\\{{ base }}"`.
- **`patterns`** *(list[object], required)* — список описаний объектов для установки/удаления/копирования.
- **`patterns__*`** *(list[object], optional)* — дополнительные списки, которые через `merge_variables` объединяются в единый эффективный список (см. ниже).

---

## Алгоритм объединения `patterns`

Все переменные, чьё имя начинается с `patterns__`, объединяются с `patterns` в итоговый список `patterns_effective` (в порядке приоритета Ansible). Это позволяет наслаивать общие и хостовые правила.

```yaml
# Пример
patterns__base:
  - regex: '(?i)^7z.*\\.msi$'
    mode: msi
    args: ['/qn']

patterns:
  - regex: '(?i)^TorBundle.*\\.(zip|7z)$'
    mode: arc
    dest: 'C:\\Tools\\Tor'
```

---

## Элемент списка `patterns`

Обязательные и общие поля:

- **`regex`** *(string, required)* — регулярное выражение для выбора файла из `local_dir` (регистронезависимый поиск по имени файла). Если найдено несколько — используется «самый новый» по версии, извлечённой из имени.
- **`mode`** *(string, optional)* — режим обработки. Допустимые значения: `exe`, `msi` (оба — ветка **pkg**), `arc`, `files`. По умолчанию — `exe`.
- **`state`** *(string, optional)* — целевое состояние: `present` | `absent`. По умолчанию — `present`.
- **`dest`** *(string, optional)* — базовая папка назначения для режимов `arc` и `files`. Если не указана — берётся глобальная `dest`.
- **`pre`** *(string | list[string], optional)* — команды, выполняемые **до** основной операции на хосте Windows.
- **`post`** *(string | list[string], optional)* — команды, выполняемые **после** основной операции на хосте Windows.
- **`force`** *(bool, optional, default: false)* — игнорировать маркер `*_installed` и выполнять действие снова.

### Поля для режима **pkg** (`exe`/`msi`)

- **`args`** *(list[string], optional)* — аргументы командной строки для `win_package`.
- **`product_id`** *(string, optional)* —
  - при `state: present` — может задавать GUID/ID пакета;
  - при `state: absent` — используется как **regex по имени** установленного приложения для поиска в кастомных фактах, если GUID отсутствует; в этом случае будет выполнен `uninstall_string` из реестра.
- **`creates_path`** *(string, optional)* — путь‑сигнал успешной установки.
- **`expected_return_code`** *(list[int], optional, default: `[0, 3010]`)* — допустимые коды возврата.
- **`wait_for_children`** *(bool, optional, default: true)* — ожидать дочерние процессы.

> Источник пакета:
> - если задан `remote_source` — пакет берётся **напрямую** из `remote_source` (без `win_copy`);
> - иначе файл предварительно копируется в `{{ dest }}\\{{ base }}` и оттуда устанавливается.

> Удаление через `uninstall_string`:
> если `product_id` в фактах отсутствует, а имя приложения совпадает с regex из `patterns[*].product_id`, запускается `uninstall_string` (включая автоконверсию вида `MsiExec.exe /I{GUID}` → `MsiExec.exe /X "{GUID}" /quiet /norestart`).

### Поля для режима **arc**

- **`files`** *(list[string], optional)* — относительные пути из распакованного архива, которые нужно скопировать. Если не задано/пусто — копируется **всё содержимое** распаковки.
- **`dest`** *(string, optional)* — папка назначения (по умолчанию глобальная `dest`).
- **Поведение `state: absent`**:
  - если `files` заданы — удаляются только перечисленные пути внутри `dest`;
  - иначе — удаляется весь каталог `dest`.

### Поля для режима **files**

- **`files`** *(list[string], required)* — относительные пути из `local_dir`, которые копируются на хост как **шаблоны** (Jinja2). Подкаталоги создаются автоматически.
- **`dest`** *(string, optional)* — папка назначения (по умолчанию глобальная `dest`).
- **Поведение `state: absent`** — удаляются перечисленные файлы в `dest`.

---

## Итоговые факты и отчёт

- **`_arc_success`** *(list[string])* — успешные элементы для режима `arc`.
- **`pkg_success`** *(list[string])* — успешные элементы для режима `pkg`.
- **`_files_success`** *(list[string])* — успешные элементы для режима `files`.
- **`success_items`** *(list[string])* — объединение всех успешных: `pkg_success ∪ _arc_success ∪ _files_success`.
- **`success_total`** *(int)* — суммарное количество успешных элементов по всем хостам (для Telegram).

---

## Мини‑пример `patterns`

```yaml
patterns:
  - regex: '(?i)^7z.*\\.msi$'
    mode: msi
    args: ['/qn', 'ALLUSERS=1']
    creates_path: 'C:\\Program Files\\7-Zip\\7z.exe'

  - regex: '(?i)^TorBundle.*\\.(zip|7z|tgz)$'
    mode: arc
    dest: 'C:\\Tools\\Tor'
    files:
      - 'torrc'
      - 'scripts\\install.bat'

  - regex: '(?i)^torrc$'
    mode: files
    dest: 'C:\\Tools\\Tor'
    files:
      - 'torrc'
      - 'tor_install.bat'
```

---

## Принцип работы (flow)

1. Скан в контейнере `local_dir` (`/source`), сопоставление по `regex` и выбор максимальной версии из имени.
2. Проверка маркеров `_installed` в `dest` (для идемпотентности, `force: true` игнорирует маркер).
3. Выполнение `pre` команд.
4. Обработка по режимам: **arc/pkg/files**.
5. (Для `pkg: absent`) удаление через `win_package` или запуск `uninstall_string` из фактов (с автоправками `msiexec`).
6. Выполнение `post` команд.
7. Сбор итогов `_arc_success`, `pkg_success`, `_files_success` → `success_items` → `success_total`.
8. Отправка Telegram‑отчёта (`telegram.yaml`).

---

## Полезные подсказки для Docker

- При SELinux используйте `:z` при монтировании: `-v "$PWD"/win_soft_management:/work:z -v "${SOURCE_DIR}":/source:z`.
- Если нужно выполнить разовый `ansible -m ping`, используйте:
  ```bash
  docker run --rm -it -v "$PWD"/win_soft_management:/work -w /work quay.io/ansible/awx-ee:latest \
    ansible -i inventory.yaml -m ping all -o
  ```
- Для приватных коллекций пробрасывайте токены/SSH‑ключи в контейнер через переменные окружения/монтирование.

---

## Структура (рекомендуемая)

```
win_soft_management/
├─ playbook.yml
├─ requirements.yaml
├─ task_arc.yaml
├─ task_files.yaml
├─ defender.yaml
├─ clear_markers.yml
├─ telegram.yaml
├─ inventory.yaml
├─ run.sh
└─ (монтируемый) SOURCE_DIR → /source
```

---

## Лицензия

MIT
