# uncensored-local-agent

Одна команда, и на macOS или Linux работает **полностью локальный агент для разработки без цензуры
на open-weight моделях**:
- [llama.cpp](https://github.com/ggml-org/llama.cpp) запускает abliterated-версии Qwen (Heretic/ARA);
- [llama-swap](https://github.com/mostlygeek/llama-swap) переключает их за одним OpenAI-совместимым endpoint;
- [OpenCode](https://opencode.ai) работает поверх них как агент со скиллами [superpowers](https://github.com/obra/superpowers): brainstorm → spec → plan → сабагенты.

Без облака, ключей и телеметрии стека; модели по умолчанию не отказывают. Всё ставится в домашний
каталог, root не нужен.

> Исследование, на котором основан выбор моделей: [docs/RESEARCH.ru.md](docs/RESEARCH.ru.md).
> Каталог и профили: [docs/MODELS.md](docs/MODELS.md). English: [README.md](README.md).

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/mark-ssd/uncensored-local-agent/v0.1.0/install.sh | bash
ula test      # чат, tool calls, эмбеддинги и rerank для каждой модели
ula agent     # OpenCode на локальных моделях, запускать в папке проекта
```

Флаги: `--profile ИМЯ` (по умолчанию определяется по ОС, RAM и GPU), `--all-models` (плюс стоковые
версии моделей), `--no-models`, `--no-service`, `--no-superpowers`. При установке через
`curl | bash` передавайте их так: `... | bash -s -- --all-models`.

Переменные окружения:
- `ULA_MODELS_DIR` — модели на другом диске;
- `ULA_PORT` — порт, по умолчанию 8090;
- `ULA_ACCEL=cpu|cuda|rocm|vulkan` — принудительно выбрать сборку llama.cpp.

## Что ставится

| Имя модели | Роль |
|---|---|
| `coder` | быстрый исполнитель агентного цикла, uncensored |
| `architect` | модель для дизайна, планов и ревью, uncensored |
| `coder-stock`, `architect-stock` | оригинальные веса без abliteration (с `--all-models`) |
| `embed`, `rerank` | Qwen3 embedding и reranker для code RAG |
| `<имя>:fast` | та же модель с выключенным thinking |

Эти имена одинаковы во всех профилях. Endpoint `http://127.0.0.1:8090/v1` подходит любому
OpenAI-совместимому инструменту (Aider, Continue, Cline, свой харнесс): модель `coder`, ключ любой.

В OpenCode:
- агент `build` работает на `coder`;
- `plan` и агент `architect` — на `architect`;
- `@reviewer` — ревьюер только на чтение;
- скиллы superpowers грузятся инструментом `skill`.

**Профили железа (15 штук):**
- Mac 16/24/36/64/128 ГБ, NVIDIA 16/24/32/48/96 ГБ, CPU 16/32/64 ГБ, unified-память 128 ГБ (Strix Halo, DGX Spark), `tiny`;
- полная таблица в README.md;
- на реальном железе прогнаны `mac-24gb` и `tiny`; остальные рассчитаны по заголовкам GGUF и бюджету памяти и прошли состязательное ревью, но не запускались. На своём железе прогоните `ula test` и напишите в issue.

Замеры на M4 Pro 24 ГБ: coder обрабатывает промпт со скоростью 827 tok/s и генерирует 66 tok/s, architect — 123 и 12,8 tok/s. Реальная задача в OpenCode (модуль, тесты pytest, прогон) заняла 64 с.

**Профиль `mac-24gb`** (MacBook M4 Pro 24 ГБ):
- coder: Qwen3.6-35B-A3B Heretic (Native-MTP-Preserved) i1-IQ3_S, контекст 64K;
- architect: Qwen3.8-27B Heretic-ARA IQ3_M, контекст 32K.

Metal даёт GPU ~17,8 ГиБ, поэтому одновременно в памяти одна чат-модель. Вызов архитектора
выгружает coder: ~10–20 с плюс повторное чтение промпта. На профилях от 64 ГБ обе модели
загружены одновременно.

## Команды

```bash
ula agent                 # TUI; Tab переключает build/plan
ula agent run "почини падающий тест"    # разовая задача без TUI
ula status | models | doctor | logs
ula unload                # освободить память сразу
ula pull --all            # докачать все модели профиля
ula profile mac-64gb && ula pull       # сменить профиль железа
ula bench coder           # скорость prefill и генерации
ula catalog verify        # все ли файлы на HF на месте и с тем же sha256
```

## «Без цензуры»: что это значит здесь

- **Веса.** Heretic/ARA-abliteration моделей Qwen под Apache-2.0. Направление отказа убрано
  с низкой KL-дивергенцией, потеря качества небольшая (цифры в docs/RESEARCH.ru.md). Политическую
  «подачу» китайских базовых моделей abliteration не убирает.
- **Харнесс.** Системные инструкции велят отвечать прямо и без морализаторства. Отключены:
  бесплатные облачные модели OpenCode, загрузка каталога моделей, импорт скиллов Claude Code и
  шаринг сессий.
- **Не проверено независимо:** качество tool calling у abliterated-моделей. Проверяйте сами через
  `ula test` и свои задачи; для сравнения есть `coder-stock`.
- **Удаления с HF.** Hugging Face иногда удаляет uncensored-репозитории. Держите копии нужных
  GGUF. `ula catalog verify` (и еженедельный CI) покажет, если файл исчез.

## Безопасность

- **Права агента.** Он выполняет shell-команды от вашего пользователя и с полным доступом к сети.
  По умолчанию OpenCode разрешает всё; этот репо добавляет подтверждение только для `git push`
  и `sudo`.
- **Модели без цензуры выполнят и разрушительную просьбу.** Для недоверенных задач используйте VM,
  контейнер или отдельного пользователя.
- **Роутер и все llama-server закрыты ключом** (`~/.config/ula/api-key`, права 0600). CORS разрешён только своему origin, захват запросов выключен, поэтому страницы в браузере не прочитают ваши промпты с `127.0.0.1`.
- **Конфиг OpenCode из чужого репозитория** (`opencode.jsonc`, `.opencode/`) игнорируется: он мог бы перенаправить провайдера или выдать себе права. Включить на один запуск: `ULA_PROJECT_CONFIG=1 ula agent`.
- **Каждый бинарник и каждая модель** проверяются по sha256, закреплённому в репо; при несовпадении установка останавливается.
- **OpenCode ходит только к локальному провайдеру.** Веб-поиск (Exa) выключен, включить можно через `ULA_WEBSEARCH=1`.

## Удаление

```bash
ula uninstall
rm -rf ~/.local/share/ula ~/.config/ula
```

Конфиг OpenCode лежит в `~/.config/opencode`, рядом бэкап прежнего конфига.

Версии закреплены: llama.cpp `b12176`, llama-swap `v270`, OpenCode `2.2.5`, superpowers `v7.0.2`.
Каждая загрузка проверяется по sha256. Лицензия репо — MIT. У моделей и инструментов свои лицензии;
на закреплённых версиях все они пермиссивные.
