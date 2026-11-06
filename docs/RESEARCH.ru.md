# Локальные open-weight модели для проектирования, ресёрча и разработки сложных систем и агентных харнессов: отчёт на 2026-11-06

> **Дата среза:** 2026-11-06.
>
> **Метод:** мультиагентное исследование (9 тематических треков и 6 треков добора пробелов) с состязательной проверкой фактов: каждое утверждение перепроверялось по первоисточникам (HF API, model cards, LICENSE, GitHub, лидерборды). Подробности в разделе 2.
>
> **Оговорка:** цифры, версии, цены и лицензии в этой области меняются каждый месяц. Считайте всё ниже снимком на дату среза и перед решением перепроверяйте по ссылкам из раздела 11. Номера версий и флаги CLI особенно быстро устаревают.
>
> Это исследование, из которого выросли решения репозитория. Точные пины лежат в `lib/common.sh` и `catalog/models.tsv`, а устройство каталога описано в [MODELS.md](MODELS.md).

## Где репозиторий отходит от отчёта

Решения ниже приняты после проверки руками и важнее рецептов из раздела 9:

- **OpenCode v2.2.5.** Конфиг генерирует `lib/render.sh`, его ключи сверены со схемой [opencode.ai/config.json](https://opencode.ai/config.json): `providers.<id>.package` / `settings.baseURL`, `compatibility.reasoningField`, `limit.context`, равный `--ctx-size` модели. JSONC-примеры в рецептах взяты из документации v2 и построчно не проверялись.
- **llama.cpp закреплён на релизе b12176** (готовые tarball'ы с GitHub, sha256 сверяется с GitHub release API), а не на «brew, b12175 или новее». Требование отчёта «билд не старше конца октября 2026» этот пин выполняет.
- **Реранкер `ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF`.** Отчёт советует брать только официальный GGUF, но у Qwen официальный GGUF есть только для Qwen3-Embedding, а для Qwen3-Reranker его нет. Используется конверсия от мейнтейнеров llama.cpp. `ula test` проверяет, что релевантный документ получает наивысший скор, то есть что скоры не константные.
- **Между харнессом и моделями стоит роутер llama-swap v270** на `127.0.0.1:8090`, а не один `llama-server` на `:8080`. Он держит стабильные имена моделей (`coder`, `architect`, `embed`, `rerank` и т. д.) и на 24 ГБ по очереди подгружает исполнителя и архитектора.
- **Uncensored-архитектор по умолчанию `mradermacher/Qwen3.8-27B-heretic-ara-i1-GGUF` i1-IQ3_M**, а не orcarouter: репозиторий orcarouter гейтед, и у него больше незавершённого thinking (152 против 61 из 400). Стоковые сборки из рецептов A и B доступны как `coder-stock` и `architect-stock`.
- **Плагин superpowers** (obra/superpowers, пин v7.0.2) подключается к OpenCode по умолчанию. Скиллы и агенты Claude Code в OpenCode по умолчанию не подтягиваются (`OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`), чтобы локальная конфигурация не зависела от чужих настроек.

---

---

## 1. TL;DR

- **Главный рабочий стек для MacBook M4 Pro 24 ГБ (20-ядерный GPU):**
  - Движок: `llama.cpp` (`llama-server`, MIT).
  - Агент-исполнитель: **Qwen3.6-35B-A3B UD-IQ3_S** (13,7 ГБ, Apache-2.0), контекст 32–64K.
  - Архитектор и ревьюер, загружается по требованию: **Qwen3.8-27B UD-IQ4_XS** (14,3 ГБ, Apache-2.0).
  - Харнесс: **OpenCode** (MIT). Если модель плохо держит формат tool calls, вместо него **mini-swe-agent** (MIT, работает только через bash).
  - Обе модели одновременно в память не помещаются, их нужно переключать.
- **Почему исполнитель MoE, а не плотная 27B.** Плотная Qwen3.8-27B обрабатывает промпт на M4 Pro примерно со скоростью 120–130 tok/s. Холодный агентный промпт на 32K токенов до первого ответа считается **~4–4,5 минуты**. MoE с ~3B активных параметров делает тот же prefill примерно в 5 раз быстрее (~700 tok/s на 32K в MLX) и генерирует ~55–65 tok/s против ~11–13 у плотной.
- **Варианты без цензуры для 24 ГБ:**
  - Исполнитель: `mradermacher/Qwen3.6-35B-A3B-uncensored-heretic-i1-GGUF`, файл i1-IQ3_XS (14,5 ГБ) или i1-IQ3_S (15,25 ГБ). Это Heretic MPOA от llmfan46: KL 0,0015, на UGI независимо W/10 2,2 → 10,0 без потери NatInt.
  - Архитектор: `orcarouter/Qwen3.8-27B-Uncensored-GGUF` IQ3_M (максимальная готовность отвечать) или `mradermacher/Qwen3.8-27B-heretic-ara-i1-GGUF` i1-IQ3_M (меньше зацикливаний, лучший HumanEval).
  - **Ни у одной abliterated-сборки нет независимого замера качества tool calling.** Перед боевым использованием проверьте её сами (раздел 10).
- **Ограничения M4 Pro 24 ГБ:** Metal даёт GPU не больше 17,76 GiB (`recommendedMaxWorkingSetSize`, измерено на MacBook M4 Pro 24 ГБ). Qwen3.8-27B в Q4_K_M и больших квантах, Nanbeige4.3-33B и Flint в Q3_K_XL+ в роли агента не подходят. Ollama для Qwen3.6/3.8 здесь не рекомендуется: GGUF с отдельным mmproj не грузятся, а официальные теги весят 18 ГБ.
- **Что меняет апгрейд железа:**
  - **Mac mini M5 Pro 64 ГБ (~$2 699).** Flint 40B-A2.5B (Apache) на движке `rec` даёт ~145 tok/s, промпт 32K обрабатывается ~20 с. Prefill в 3–4 раза быстрее, чем на M4 Pro 24 ГБ.
  - **Mac Studio M5 Max 128 ГБ (~$5 100, оценка по прайсу апгрейдов).** gpt-oss-120b (Apache): ~65 tok/s, ~2 500 tok/s prefill на 32K.
  - **M5 Ultra 256–512 ГБ ($10,8–22,3 тыс.).** GLM-5.3-Flash (MIT) и DeepSeek V4.1-Flash (MIT) локально.
  - **M6 MacBook Pro не покупать:** у него 153–170 ГБ/с против 273 ГБ/с у M4 Pro, максимум 32 ГБ и Thunderbolt 4.
- **Лучшая open-weight модель вообще** — Kimi K3.1 Pro: AA v5 = 46, Vals TB4 = 63,64% против 65,15% у Opus 5.5. Но это 2,8T параметров и ~1,56 ТБ весов, то есть только мультинодовый сервер. Лицензия кастомная, данные по кибербезопасности вырезаны из обучения.
- **Разрыв с закрытым фронтиром, честно:**
  - По композитному индексу: лучшая открытая модель 46, лучшая закрытая 60. Локальная Qwen3.8-27B набирает 20.
  - На задаче «построить программу с нуля» (Vals ProgramBench): Opus 5.5 18,5%, лучшая открытая 2,0%, Qwen3.8-27B 0%.
  - Для 24 ГБ это значит: модель годится как инструмент-помощник, но не как автономный архитектор сложной системы.

---

## 2. Как читать этот отчёт

- **Дата среза:** 2026-11-06. Область меняется еженедельно: за июнь–ноябрь 2026 вышло больше 20 значимых open-weight моделей.
- **Метод:**
  - 9 исследовательских треков: frontier MoE, локальный класс, reasoning/long-context/deep-research, цензура, лицензии, движки, харнессы, бенчмарки, железо.
  - Состязательная проверка фактов: каждое утверждение перепроверено по первоисточникам (HF API, model cards, LICENSE, GitHub, лидерборды).
  - 6 треков добора пробелов.
  - Утверждения, помеченные как REFUTED, в отчёт не вошли. Исправления CORRECTED и STALE применены. Непроверенное помечено **(не подтверждено)**.
- **Оговорки:**
  - **Self-reported ≠ независимые цифры.** Вендорские Terminal-Bench 2.1 (там все в районе 80) нельзя сравнивать с независимым TB 4.0. Пример: Beam 1.0 сообщает о себе 80,1% на TB2.1, а Vals намерил 4,04% на TB4. DeepSeek V4.1-Flash: 42,3 по своим данным против 31,82 у Vals. ProgramBench у него 29,1 против 0,5.
  - **Контаминация.** SWE-bench Verified фактически выведен из оборота: OpenAI перестал его публиковать 2026-02-23, Vals его архивировал. При переходе AA на приватные тесты (v5) открытые модели просели заметно сильнее закрытых: DeepSeek V4.1 Flash 45 → 32, Muse Spark Open 39 → 25.
  - **Харнесс влияет на результат.** Разброс между харнессами для одной и той же модели составляет 2–10 п.п. Китайские модели дообучают под схему инструментов Claude Code.
  - **Собственный бенчмарк при подготовке отчёта не запускался:** для него нужны установка, ~28 ГБ загрузок и риск зависания 24-гигабайтной машины. Цифры для M4 Pro взяты из опубликованных замеров на соседних конфигурациях. Протокол самопроверки описан в разделе 10.

---

## 3. «Без цензуры» и «полностью открытая»: что это значит на практике

### 3.1. Уровни открытости. Они проверяются отдельно

| Уровень | Что означает | Примеры (ноябрь 2026) |
|---|---|---|
| **L1. Строгий OSAID**: веса, данные, код и рецепт | Можно воспроизвести модель с нуля | OLMo 3/3.1, **Olmo Hybrid 7B** (2026-03-05), K2-V2 / K2 Think V2, **K2-Horizon 375B-A23B** (Apache, данные, рецепт, код и чекпойнты открыты), Apertus 1.5, Marin, SmolLM3. У K2-Horizon-MoVA-36B источники расходятся: по одним данные и код опубликованы, по другим «пока нет» **(не подтверждено)** |
| **L2. OSI-лицензия на веса (Apache-2.0 / MIT), без AUP** | Любое использование, модификация, abliteration | Qwen3.8-27B, Qwen3.6, Qwen3-Coder-Next, Gemma 4, gpt-oss, Devstral Small 2, Mistral Small 4, Nanbeige4.3-33B, Flint, Ripple-65B, Mellum 2.1, North Mini Code; MIT: DeepSeek V4/V4.1, GLM-5.2, GLM-5.3-Flash, GLM-4.7-Flash, MiMo-V2.6, Ling-3.1, LongCat-2.0; Apache: Inkling/Inkling-Small, Beam, Hy3/Hy4-preview, Step-3.7-Flash |
| **L3. Пермиссивная, но не OSI** | Практически свободна, формально не OSI | OpenMDW-1.1 (Nemotron 3 Ultra и 3.5, Laguna XS/S 2.1): подана в OSI в августе 2026, не одобрена. NVIDIA Nemotron Open Model License (Dec 2025): без guardrail-оговорки |
| **L4. Кастомная, только пороги выручки или атрибуции** | Одиночному пользователю и фирме до $20–50 млн выручки не мешает | Kimi K3 / K3.1 Pro (MaaS > $20M/12 мес. требует договора; внутреннее использование освобождено; AUP нет); GLM-5.3 полная (MaaS > $10B проходит security review Z.ai); Qwen3.8-2.4T (MaaS или «AI Work Assistant» > $50M); Qwen3.8-Flash-Next (qwen-community-1.0); Mistral Large 4 (MaaS требует коммерческой лицензии) |
| **L5. AUP, запреты или гейтинг: не подходит** | Есть юридические ограничители | **MiniMax M3/M3.1** (базовый грант некоммерческий, военное использование запрещено); **Muse Spark Open** (гейт с датой рождения и ID, AUP, деривативы включают модели, обученные на её выходах); **NVIDIA Open Model License (Oct 2025)**: права **автоматически прекращаются** при обходе guardrails (Nemotron Nano 9B/12B v2, Llama-3.3-Nemotron-Super-49B-v1.5); Llama 4 (AUP, EU-исключение для мультимодальных); Devstral 2 123B (запрет при выручке > $20M/мес.); AMD Instella-MoE (ResearchRAIL); jina-code-embeddings (CC-BY-NC) |

**Скрытые ограничения уровня «README» (layer 3).** Лицензию они не меняют, но показывают намерения издателя:
- **MiMo-V2.6-Pro-RL.** Тег MIT, но файла LICENSE в репозитории нет. С 2026-10-28 в README есть блок «Use Restrictions»: военные цели, вредоносные кибер-действия, «автономное выполнение рисковых действий без надзора человека». Сам блок называет себя «informational reminder only».
- **Muse Glimmer 30B (Meta).** Лицензия — дословный Apache-2.0, но рядом лежит `USAGE_POLICY.md`. Его п. 1.8 прямо просит не «circumvent or remove … safety measures», то есть не делать abliteration. Плюс safety-RL в весах. Юридическая сила слабая, но это самый «цензурный» текст среди Apache-моделей.
- **Laguna XS 2.1 и карточки Nemotron 3/3.5:** «advise against circumventing guardrails». Это совет, не условие лицензии.
- **Gemma 4:** чистый Apache-2.0. Ссылка на Prohibited Use Policy (2024) — остаток навигации сайта для Gemma 1–3, на Gemma 4 она юридически не распространяется. Веса при этом safety-tuned.
- **Kimi K3.1 Pro.** Moonshot **вырезал данные по кибератакам** из mid-training и RL: внутренний xdev-bench-hard 81,0% против 90,5% у нефильтрованной версии (данные вендора, пересказ в прессе). Abliteration снимает только отказы, отсутствующие знания она не вернёт.

**Где основные кандидаты:**
- Qwen3.8-27B, Qwen3.6-35B-A3B, Gemma 4, gpt-oss, Flint, Ripple, Nanbeige, GLM-5.3-Flash и DeepSeek V4.x — это **L2**: OSI-лицензия, abliteration юридически чиста.
- **Если нужен строгий L1:** на 24 ГБ доступны только OLMo 3.1 32B (впритык в Q4) и Olmo Hybrid 7B. Разрыв с L2-моделями огромный: лучший fully-open агентный результат на SWE-bench Verified ~54% (SERA-32B, и та на базе Qwen3, то есть не L1) против ~78–81% у open-weight. На AA v5 OLMo, K2 и Apertus вообще не представлены.
- **Рекомендация:** L2 + аудит данных/рецепта не требуется. L1 оставьте для задач, где нужна воспроизводимость обучения, а не качество.

### 3.2. Отказы у стоковых моделей (независимые измерения)

**UGI, W/10.** Шкала «насколько далеко можно толкнуть модель до отказа», 0–10, CSV от 2026-10-17. **Строк для моделей августа–ноября 2026 нет:** Qwen3.8, GLM-5.3, Kimi K3, DeepSeek V4.1 не тестировались.

| Модель | W/10 стоковая | Лучшая uncensored-сборка, W/10 / NatInt |
|---|---|---|
| gpt-oss-20b / 120b | 0,5 / 2,0 | ArliAI gpt-oss-120b-Derestricted: 9,2 / 35,70 (выше стока 33,68) |
| Qwen3.6-35B-A3B (think) | 2,2 | llmfan46 heretic: 10,0 / 31,62 (сток 31,03) |
| Qwen3.6-27B | 2,8 | llmfan46 heretic-v2: 9,5 / 29,17 (сток 33,16) |
| Gemma 4 31B | 1,2 | coder3101 heretic: 10,0 / 36,53 (сток 38,91) |
| Muse Glimmer 30B | 3,8–4,2 | uncensored-строк нет |
| **DeepSeek-V4-Flash (reasoning off)** | **7,2** | нативно пермиссивна |
| GLM-4.7-Flash / GLM-4.5-Air | 6,8 / 7,0 | нативно пермиссивны |
| Devstral Small 2 24B | 6,8 | нативно пермиссивна |
| Mistral Small 4 119B | 4,5 | нативно умеренная |

**SpeechMap** (доля полностью отвеченных спорных запросов). Измеряет другое, чем UGI, и, вероятно, ходит через хостинг-API **(не подтверждено)**:
- gpt-oss-20b 26,8%; Qwen3.8-27B 38,5% (46,3% в reasoning); Qwen3.6-35B-A3B 28,8% (65,8%).
- DeepSeek V4.1-Flash 52,6%; GLM-5.3 71,5%; Kimi K3 65,9%; MiniMax M3 27%.
- Gemma 4 31B 84,8%; **Mistral Small 4 90,9%**.
- Линейка Qwen заметно «закрутилась» после Qwen3: было 86–90%, стало 29–46%.

**Насколько это мешает в SWE-работе:**
- Архитектура, рефакторинг и харнессы отказов почти не вызывают.
- Безопасность вызывает: по Scale AI (ICLR 2026) hardening отклоняется в 43,8% случаев, анализ малвари в 34,3%, ключевые слова «exploit/payload» повышают риск отказа в 2,72 раза. **Фраза «я авторизован» отказы увеличивает:** 11,6% → 21,8%.
- На Vul4J выровненная модель против abliterated: годный патч 29,9% против 67,8%, и почти весь разрыв даёт отказ отвечать (данные вендора Featherless).

### 3.3. Политическая цензура китайских моделей

- **Aleph Alpha, 967 промптов, доля сбалансированных ответов:** Qwen3.6-35B-A3B 17%, Qwen3.8-2.4T 19%, DeepSeek V4-Pro-0813 18%, Kimi K3 41%, **Mistral Small 4 — 92%**.
- Стоковая Qwen3.8-27B цензурировала 98 из 113 вопросов Pan & Xu (Interpretic AI, данные вендора).
- **Abliteration это не лечит.** Она убирает направление отказа, а политическая цензура в основном «мягкая»: подача и формулировки. Нужен SFT или точечные правки (Hirundo «Westernized», Interpretic). Мягкую цензуру разные судьи оценивают по-разному: 30,3% у строгого и 10,2% у открытого (lab.cloud).
- **Тихая порча кода.** По данным вендоров (CrowdStrike, Hirundo), DeepSeek-R1 и Qwen3-Coder пишут менее безопасный код, если в промпте упомянуты «чувствительные» для КНР стороны.
- **Вывод:** для геополитического ресёрча используйте Mistral (Small 4 на 128 ГБ, Devstral Small 2 на 24 ГБ) или Gemma 4, а не китайские базы.

### 3.4. Uncensored-варианты и цена, которую за них платят

**Инструменты:**
- **Heretic v2.0.0** (2026-11-01, AGPL-3.0). По умолчанию использует ARA (Arbitrary-Rank Ablation), направленную абляцию с MPOA можно включить отдельно. Конфиги 1.x несовместимы. LoRA-движок с 4-битом появился ещё в v1.2.0.
- **Norm-preserving biprojected** (grimjim, сборки ArliAI «Derestricted»).
- **OBLITERATUS:** на Hugging Face Spaces телеметрия включена по умолчанию.

**Цена в качестве.** Независимые данные: Abliterlitics по Qwen3.8-27B, lm-eval на vLLM, HarmBench с судьёй.

| Вариант | Judge ASR | Незавершённый thinking /400 | HumanEval | IFEval | MMLU-Pro | KL |
|---|---|---|---|---|---|---|
| base | 4,5% | 1 | 79,3 | 82,07 | 62,82 | — |
| orcarouter | **82,2%** | 152 | 78,7 | 82,44 | 62,78 | 0,068 |
| apostate | 78,7% | 119 | 79,9 | 82,99 | 62,81 | 0,044 |
| huihui | 75,6% | 174 | 78,7 | 81,89 | 62,67 | 0,053 |
| rvn (0bserverx) | 71,3% | 104 | 81,7 | — | — | 0,084 |
| trohrbaugh ARA | 57,5% | 61 | **82,3** | 82,26 | 62,65 | 0,059 |
| davidau | — | **23** (минимум) | — | +7,4 п.п. | — | — |
| **obliteratus** | 63,9% | 179 | **45,7** | 77,63 | 56,49 | **1,54** (сломан) |

**Как читать таблицу:**
- Число отказов и реальная готовность отвечать — разные метрики. У trohrbaugh по самоотчёту 0–3 отказа из 100, а judge ASR всего 57,5%.
- Зацикливание thinking проявляется на «вредных» промптах. На GSM8K доля пустых ответов 0–0,2% у всех вариантов.
- IFEval, ближайший прокси дисциплины формата и JSON, остаётся в пределах ±1 п.п. у всех, кроме obliteratus.
- **Независимого BFCL, tau2, SWE-bench или Terminal-Bench ни для одной abliterated-модели нет.** На практике tool calls ломаются в основном из-за шаблонов и рантаймов, а не из-за abliteration.
- Квантование тоже бьёт по инструментам: 4-бит увеличивает галлюцинации имён инструментов до 2,5 раза при «плоском» итоговом скоре (arXiv 2607.27275).
- **Правила выбора сборки:** KL ≤ ~0,2; методы ARA, MPOA или norm-preserving; проверять каждую сборку отдельно. Пример сломанной сборки: Mistral-Small-3.2 «ultra-uncensored-heretic» с NatInt 5,09.

**Риск удаления.** HF отключил `penclaw-GLM-5.3-abliterated-for-offensive-cyber` по Content Policy. `huihui-ai/Kimi-K2.7-Code-abliterated` отдаёт 404, причина не подтверждена. Под ударом в первую очередь репозитории с брендингом под offensive cyber. **Скачивайте нужные файлы и храните у себя.**

---

## 4. Ландшафт моделей

### 4.1. Frontier MoE (≥100B). На 24 ГБ не запускается ни одна

«self» — данные вендора, «[инд.]» — независимые: AA = Artificial Analysis Intelligence Index v5.0.1, Vals TB4 = Terminal-Bench 4.0 на mini-SWE-agent, MCP-Atlas = Scale.

| Модель | Дата | Total / active | Контекст | Лицензия | Бенчмарки | Tool calling | Цензура / uncensored | Железо |
|---|---|---|---|---|---|---|---|---|
| **Kimi K3.1 Pro** | API 10-23; веса на HF 11-04 (репо создан 11-02; время 15:31 UTC — не подтверждено) | 2,8T / 104B, MXFP4 QAT | 1M | Kimi K3.1-Pro License (L4) | [инд.] AA 46, Vals TB4 63,64% (#3); self TB4 65,7, DeepSWE 75,5, HLE-Full 51,1 / 70,0 с инструментами, BrowseComp 92,1 | OpenAI- и Anthropic-совместимый; нужно возвращать `reasoning_content` + `tool_calls` | Кибер-данные вырезаны; есть `audnai/penclaw-…unrestricted` | ~1,56 ТБ, мультинодовый сервер (~8×B300, по сообщениям) |
| Kimi K3 | июнь–июль 2026 | 2,78T / 104B | 1M | kimi-k3 (L4) | [инд.] Vals TB4 17,17%, ProgramBench 2,0% (лучший из открытых), MCP-Atlas 82,3; self TB2.1 88,3 | thinking всегда включён | — | сервер |
| **DeepSeek V4.1-Flash-1017** | 2026-10-17 | 763B в метаданных (552B + 196B Engram; 8B/16B active) | 1M | **MIT** | [инд.] AA 33 (лучшая с выпущенными весами на момент v5), Vals TB4 31,82%, SkillsBench #1 69,8% (база V4.1), FrontierCode 28%; self DeepSWE 77,0, TB4 42,3 | Jinja-шаблона нет; `encoding/` или deepseek-recipe | UGI V4-Flash W/10 7,2; dealignai UNCENSORED-FP8, huihui / orcarouter abliterated GGUF | Unsloth GGUF: IQ1_S 233 ГБ … Q8_K_XL 508 ГБ, нужен PR Unsloth для llama.cpp; ktransformers |
| DeepSeek V4-Pro-0813 | 2026-08-13 | ~1,65T / 49B | 1M | MIT | self TB2.1 87,9, DeepSWE 62,7; SkillsBench 53,83% [инд.] | то же + DSpark-драфтер | Aleph 18% сбалансированных ответов | ~1 ТБ |
| DeepSeek V4-Flash-0731 | 2026-07-31 | 284B / 13B | 1M | MIT | — | то же | UGI W/10 7,2 (reasoning off) | ~160 ГБ FP4: M5 Ultra 256 ГБ 48–54 tok/s со спекуляцией (39/33 без) |
| **GLM-5.3** | 2026-08-25 | 753B / ~40B | 1M | glm-5.3 (L4, порог $10B) | [инд.] AA 32, Vals TB4 38,89%, MCP-Atlas 84,2; self TB2.1 88,2, DeepSWE 66,9 | reasoning_effort, clear_thinking | SpeechMap 71,5% | ~420–450 ГБ Q4 (оценка) |
| **GLM-5.3-Flash** | 2026-08-25 | 320B / 18B | 1M | **MIT** | [инд.] Vals TB4 37,37% при $1,22 за тест; self TB2.1 84,3, DeepSWE 63,4 | то же | SpeechMap 65,4%; скачиваемых abliterated GGUF не найдено | ~176–210 ГБ Q4; UD-IQ3_XXS ~120 ГБ |
| MiMo-V2.6-Pro | 2026-09-21 (MOPD 09-27) | 1,02T / 42B | 1M | MIT (без файла LICENSE, notice с 10-28) | [инд.] AA 30, Vals TB4 31,31% (self 34,9) | MiMo Code (MIT) | dealignai ABLITERATED | ~570 ГБ Q4 (оценка) |
| Ling-3.1-flash-1019 | 2026-10-27 | ~560B / 25B | 262K (1M заявлено) | MIT | [инд.] AA 30 | гибридный reasoning | — | ~574 ГБ |
| MiniMax M3 / M3.1-Flash | 06-02 / 10-17 | 428B / 23B | 1M | **L5** (некоммерческая, без военного использования) | [инд.] M3.1-Flash AA 29, Vals TB4 25,25%; M3 1,01% | — | **исключена по лицензии** | ~240 ГБ Q4 |
| Qwen3.8-2.4T-A95B | август 2026 | 2,4T / 95B | 262K → 1M | qwen3.8-max (L4) | [инд.] Vals TB4 38,89% (тестировался «Qwen 3.8 Max 0902», возможно API-версия), MCP-Atlas 84,5 | thinking нельзя выключить | Aleph 19% | >400 ГБ даже в 1 бите |
| **Qwen3.8-Flash-Next** | 2026-08-24 | 125B / 6B + 51B n-gram + 4B MTP (~180B хранится) | 262K → 1M | qwen-community-1.0 (L4: MaaS и AI Work Assistant требуют отдельной лицензии) | self SWE-Pro 62,5, Toolathlon 73,5 | enable/preserve_thinking | SpeechMap 34,4% | **128 ГБ**: IQ4_XS 93,7 ГБ, MLX 4-bit ~112 ГБ |
| Mistral Large 4 | публично 10-29 | ~1T / 52B | 1M | Mistral Ecosystem (L4) | [инд.] AA 26, Vals TB4 26,26% | — | Mistral заявляет 96,6% отказов на вредоносный кибер | FP8 1,06 ТБ, NVFP4 ~610 ГБ |
| Muse Spark Open | 10-15 | 816B / 42B | 1M | Muse (L5, гейт) | [инд.] AA 25 | — | AUP | 2–4 × M5 Ultra (MLX RDMA) |
| Inkling-Small | июль 2026 | 276B / 12B | 1M | Apache-2.0 | self SWE-Pro 55,9, TB2.1 64,7; в AA нет | не документирован | карточка советует ставить Llama Guard | ~155–165 ГБ Q4 (оценка) |
| Reflection Beam 1.0 | публично 10-16 | 501B / 23B | 1M | Apache-2.0 | [инд.] **Vals TB4 4,04%**, AA 18; self TB2.1 80,1 | Mirror CLI | deliberative alignment | ~280 ГБ Q4 |
| Nemotron 3 Ultra | 06-04 | 550B / 55B | 1M | OpenMDW-1.1 (L3) | [инд.] AA 12, MCP-Atlas 63,1; self SWE-V 70,7, TB2.1 56,4 | парсер `qwen3_coder` | данные в основном открыты | BF16 / NVFP4, 4×B200+ |
| K2-Horizon 375B-A23B | 09-01 | ~379B / 27B | 512K | Apache-2.0, **L1** | [инд.] AA 18 | — | — | ~210 ГБ Q4 |
| Tencent Hy4-preview / Hy3 | 08-27 / 2026 | 770B/49B; 295B/21B | >1M | Apache-2.0 | self SWE-Pro 65,7 / SWE-V 78 | — | — | BF16 / FP8 |
| Step-5-Preview | 09-20 | 604B / 27B | 1M | StepFun 1.0 (L4/5) | self DeepSWE 67,7 | `--tool-call-parser step5` | — | — |
| gpt-oss-120b | 2025-08 | 117B / 5,1B | 128K | Apache-2.0 | UGI W/10 2,0 | harmony | ArliAI Derestricted (NatInt выше стока) | ~63 ГБ MXFP4, **128 ГБ** |

### 4.2. Локальный класс (24–128 ГБ)

| Модель | Дата | Params | Контекст | Лицензия | Бенчмарки | Tool calling | Uncensored | Железо / фит |
|---|---|---|---|---|---|---|---|---|
| **Qwen3.8-27B** | 2026-08-14 | 27B плотная, гибрид (16 attention + 48 DeltaNet) | 262K (YaRN до 1M) | Apache-2.0 | [инд.] AA 20, SkillsBench 38,11%, ProgramBench 0%, TB4 (AA) 5,6%; self SWE-Pro 61,7 (Claude Code), TB2.1 73,0 (Terminus; сторонний PrismML: 69,7), GPQA 89,2 | qwen3_coder-парсер llama.cpp (≥b10227); **шаблон падает на поздних system-сообщениях** | orcarouter, trohrbaugh ARA, 0bserverx RVN, huihui | 24 ГБ: UD-IQ4_XS 14,3 / UD-Q3_K_XL 13,1 ГБ; Q4_K_M 16,5 — без запаса. Очень многословна: 128M токенов на прогон AA против медианы 77,7M |
| **Qwen3.6-35B-A3B** | 2026-04-16 | 35B / 3B MoE | 262K | Apache-2.0 | [инд.] MiaAI tool-eval **91,0** (#1 из 7, Q8), SWE-rebench 24,7%; self SWE-V 73,4, TB2.0 51,5 | qwen3_coder; KV 20 KiB/токен | llmfan46 Heretic (UGI W/10 10) | 24 ГБ: UD-IQ3_S 13,7 ГБ; Q4 от 17,7 ГБ (IQ4_XS) уже впритык |
| Nanbeige4.3-33B | 10-24/25 | 33B плотная (52 слоя, 8 KV-голов) | 512K | Apache-2.0 | [инд.] AA 20 (наравне с Qwen3.8-27B), Progress Index 306 (#1 малых); TB4 на AA 29,8% (не подтверждено); self TB2.1 80,9 | qwen3_coder + та же проблема с late-system | Luni Heretic GGUF (Apache), 0bserverx RVN, SolsticeAI (Heretic v2, только BF16), dealignai (своя лицензия) | KV **208 KiB/токен** (в 3,25 раза больше Qwen3.8): на 24 ГБ только IQ3 и 16–32K |
| Recursive Flint | 10-21 | 39,8B / ~2,5B MoE | 262K | Apache-2.0 | self TB2.1 54,9, SWE-V 74,2; в независимых тестах сфабриковал результат и вписал PLACEHOLDER | GLM-4.7-стиль; **в llama.cpp нет своего парсера** (#31000 открыт); vLLM-парсер `flint` в PR | electroglyph (7/100 и 18/100 отказов), dima6312 abliterix | 24 ГБ: UD-IQ3_XXS 14,5 ГБ; `rec` требует ≥48 ГБ. Чувствителен к квантованию |
| Gemma 4 31B / 26B-A4B | 2026-04-02 | 30,7B / 25,2B-3,8B | 256K | Apache-2.0 | [инд.] AA 4 (31B), MiaAI 81,4 (26B NVFP4); self tau2 76,9 | свой парсер | coder3101 heretic (W/10 10) | 26B-A4B 4-bit: **60,8 tok/s на 4K** на M4 Pro 24 ГБ (oMLX), пик 14,7 ГБ |
| Muse Glimmer 30B | 2026-08 | ~29,6B плотная + vision | 131K+ | Apache + USAGE_POLICY | self MCP-Atlas 75,5, AA-LCR 80,0; в одиночном тесте 24/30 против 30/30 у Qwen3.8 (зацикливания на tool calls) | DFlash-драфтер | darkc0de Heretic (11/100, KL 0,074) | IQ3_M 12,8 / IQ4_XS 15,2 ГБ; KV 13 KiB/токен |
| gpt-oss-20b | 2025-08 | 21B / 3,6B | 128K | Apache-2.0 | UGI W/10 0,5 | harmony | p-e-w heretic-ara-v3 (W/10 9,5) | ~12 ГБ, 54,5 tok/s / 498 tok/s prefill на M4 Pro 24 ГБ |
| Devstral Small 2 | 2025-12 | 24B плотная | — | Apache-2.0 | self SWE-V 68, TB2 22,5 | `mistral` | нативно W/10 6,8 | карточка рекомендует Mac с 32 ГБ |
| North Mini Code 1.0 | 06-09 | 30B / 3B | — | Apache-2.0 | [инд.] AA Coding 33,4 (Qwen3.6-35B: 35,2) | `cohere_command4` | — | w4a16 ~18–20 ГБ |
| Mellum 2.1 | 10-08 | 12B / 2,5B | 131K | Apache-2.0 | self SWE-V 47 | — | — | ~7–8 ГБ, для сабагентов |
| Laguna XS 2.1 / S 2.1 | июль 2026 | 33B/3B; 118B/8B | 1M (S) | OpenMDW (L3) | self XS SWE-V 70,9 | `poolside_v1` | — | XS: Mac 36 ГБ; S: 128 ГБ |
| Nemotron 3.5 Lightning / Bolt / Super-VL | 08-11 / 10-15 | 30B/3B; 74B/9B; 120B/12B | 1M | OpenMDW | [инд.] Super-VL AA 14, Vals TB4 0% | qwen3_coder | — | Bolt «24GB» рассчитан на NVIDIA, на Mac 24 ГБ не помещается |
| Qwen3-Coder-Next | 2026-02 | 80B / 3B | 262K | Apache-2.0 | self SWE-V 70,6 | только non-thinking | huihui abliterated (Q4_K_M 48,6 ГБ) | 64 ГБ |
| **Ripple-65B Preview** | 11-04 | 65B плотная (не 40B: это артефакт метаданных NVFP4) | 1M (config 2M) | Apache-2.0, обучена с нуля | self TB2.1 80,5, SWE-V 76,5; на хостинге 4 из 8 tool calls упали | llama.cpp ≥ b12167 | orcarouter abliterated | 64 ГБ: Q4_K_M 40,4 ГБ, ~7 tok/s на M5 Pro |
| Kolibri-1 | 10-03 | 78B / 3,5B | спорно | Apache-2.0 | агентных бенчей не найдено | — | — | 64–128 ГБ |
| K2-Horizon-MoVA-36B-A4B | 2026-09 | 36B / 4B | 512K | Apache-2.0 | [инд.] Progress 281; self TB2.1 58,6 | MLX пока не парсит её tool calls | — | 4-bit 26,4 ГБ, на 24 ГБ не помещается |
| Mistral Small 4 | 2026-03 | 119B / 6B | — | Apache-2.0 | [инд.] AA 27,8 (старый индекс) | `mistral` | нативно, SpeechMap 90,9% | 128 ГБ |
| GLM-4.7-Flash | 2026 | 30B / 3B | — | MIT | UGI W/10 6,8, SpeechMap 85,9% | glm47 | MuXodious, darkc0de | ~Q3/Q4 на 24 ГБ (оценка) |

### 4.3. Reasoning, длинный контекст, deep research

| Модель | Роль | Ключевые цифры | Лицензия | KV на токен (f16) |
|---|---|---|---|---|
| Qwen3.8-27B | архитектор | self GPQA-D 89,2, HLE 30,8; long-context скоров нет | Apache | 64 KiB (2 GiB на 32K) |
| Muse Glimmer 30B | чтение длинных документов | self AA-LCR 80,0, DeepSearchQA 74,6 | Apache + policy | 13 KiB (~1,7 GiB на 128K) |
| Gemma 4 31B | long-context | self MRCR v2 8-needle@128K 66,4% | Apache | ~40 KiB |
| Qwen3.6-35B-A3B | быстрый ресёрч-воркер | NVIDIA-харнесс: BrowseComp 48,74, AA-LCR 61,06 | Apache | 20 KiB |
| Nemotron 3.5 Bolt | ресёрч (NVIDIA) | BrowseComp 66,75, AA-LCR 64,06 | OpenMDW | — |
| MiroThinker-1.7 / 1.7-mini | deep-research агент | 235B: BrowseComp 74,0, GAIA 82,7; mini (30B-A3B) BC-ZH 72,3 | Apache | 96 KiB (mini) |
| Tongyi-DeepResearch-30B-A3B | deep-research агент | HLE 32,9, BrowseComp 43,4 | Apache | 96 KiB |
| Kimi K3.1 Pro | сервер | BrowseComp 92,1, HLE с инструментами 70,0 | L4 | MLA |
| DeepSeek V4.1-Flash | сервер | HLE 42,6 (1017); с инструментами 63,9 (версия 09-10) | MIT | 890 байт (вендор) |

- **Гибридное внимание экономит KV-кэш.** У Qwen3.6/3.8 (DeltaNet), Glimmer и Gemma (sliding window), Nemotron (Mamba) контекст 64–128K реально помещается примерно в 16 ГБ. У специализированных deep-research моделей полное внимание, поэтому на 24 ГБ им остаётся ~32–64K.
- **Официальные харнессы MiroThinker и Tongyi требуют облачных API:** Serper, Jina, E2B, Dashscope. Для полностью локальной работы используйте [local-deep-research](https://github.com/LearningCircuit/local-deep-research) с SearXNG или MiroFlow с локальными инструментами. Сам веб-поиск всё равно ходит в интернет.

---

## 5. Рейтинг по ролям

**Архитектор и исследователь** (длинные рассуждения, дизайн, критика):
1. **24 ГБ:** Qwen3.8-27B UD-IQ4_XS, режим thinking, `reasoning_effort` low/medium, разовые запросы на 16–32K. Второе мнение: Nanbeige4.3-33B (Luni Heretic IQ3_XXS 13,1 ГБ) на 16–32K.
2. **64 ГБ:** Qwen3.8-27B Q6/Q8 на 128K; Ripple-65B Q4 (медленно, ~7 tok/s).
3. **128 ГБ:** Qwen3.8-Flash-Next (лицензия L4) или gpt-oss-120b (Apache).
4. **256+ ГБ:** GLM-5.3-Flash (MIT), DeepSeek V4.1-Flash (MIT).
5. **Сервер:** Kimi K3.1 Pro, без конкурентов (AA 46).

**Исполнитель coding-агента:**
1. **24 ГБ:** Qwen3.6-35B-A3B UD-IQ3_S. Gemma 4 26B-A4B — запасной вариант с другой «школой».
2. **48–64 ГБ:** Flint + `rec` (вендорское качество ниже Qwen3.8, но очень быстро); Qwen3.6-35B-A3B Q6/Q8; Qwen3-Coder-Next.
3. **128 ГБ:** gpt-oss-120b (единственная 9/10 в 23-конфигурационном тесте на Strix Halo); Qwen3.8-Flash-Next.
4. **256+ ГБ:** GLM-5.3-Flash (Vals TB4 37,37% при $1,22 за тест), DeepSeek V4.1-Flash (SkillsBench #1).
5. **Сервер:** Kimi K3.1 Pro (Vals TB4 63,64%).

**Быстрый tool-calling воркер или сабагент:** Qwen3.6-35B-A3B (MiaAI 91,0, лучший независимый tool-eval) › gpt-oss-20b (harmony, стабильно, но жёсткие отказы) › Gemma 4 26B-A4B › Mellum 2.1 (крошечная) › Flint (быстрая, но парсер в llama.cpp не готов).

**Эмбеддинги и реранкер для code RAG:**
1. **Qwen3-Embedding-0.6B + Qwen3-Reranker-0.6B.** Apache, контекст 32K, MTEB-Code rerank 73,42. Реранкер запускается через `llama-server --reranking --pooling rank`; берите только официальный GGUF, кривые конверсии дают константные скоры.
2. **EmbeddingGemma 2** (2026-10-06). Apache-2.0, 8K, MTEB Code 78,68, ~270M параметров.
3. nomic-embed-code 7B (Apache) — для машин от 64 ГБ.
- Не использовать: jina-code-embeddings (CC-BY-NC) и EmbeddingGemma-300m первого поколения (Gemma license + AUP).

---

## 6. Железо по тирам

**MacBook M4 Pro 24 ГБ (измерено):** Mac16,7, M4 Pro 14 CPU / **20 GPU**, 24 GiB, macOS 26.3.1, 273 ГБ/с. `recommendedMaxWorkingSetSize` = **18 186 MiB = 17,76 GiB = 19,07 ГБ** при `iogpu.wired_limit_mb=0`. Оценка «~16 ГБ по умолчанию» в некоторых гайдах для такой конфигурации неверна.

| Тир | Стоимость (ноябрь 2026) | Что даёт | Измерено |
|---|---|---|---|
| **24 ГБ, M4 Pro** | — | MoE ~3B active в Q3; плотная 27B в IQ4/Q3 на 16–32K | Qwen3.6-35B-A3B 3-bit MLX ~62 tok/s, prefill 400–540 (данные автора сборки); MLX 2-bit: 692 tok/s prefill на 32K, пик 15,6 ГБ. Qwen3.8-27B: llama.cpp IQ4_XS 10,9 tok/s, pp2048 95 (M4 Pro 16c); UD-Q3_K_XL 12,6 tok/s при 16K. MLX 27B: prefill ~127–132 tok/s, пик 18,5–20,8 ГБ (на 24 ГБ не помещается выше 4K). gpt-oss-20b 54,5 / 498 |
| +диск | TB5-корпус ~$219 + NVMe (Samsung 990 Pro 4 ТБ ~$786–800) | Хранить модели снаружи: 5–6,6 ГБ/с, холодная загрузка 20 ГБ за ~4–5 с | Модели больше RAM это не ускорит |
| **48–64 ГБ** | **Mac mini M5 Pro 64 ГБ ~$2 699**; MBP OLED M5 Pro от $2 899 | Flint + `rec`, 27B Q6/Q8 с 128K, две модели в памяти, Ripple-65B | Flint на M5 Pro 48 ГБ (`rec`): prefill 2 112 / 1 657 / 817 tok/s (4K/32K/128K), decode 143 / 88,6 / 43,1. Gemma-4-26B Q8: pp512 1 610. Ripple-65B ~7 tok/s |
| **128 ГБ** | Mac Studio M5 Max 128 ГБ **~$5 099** (по прайсу апгрейдов; источники называют $5 099–5 400, не подтверждено); MBP 14" M5 Max 128 ГБ ~$7 099; DGX Spark 128 ГБ **$6 950**; Strix Halo 128 ГБ ~$3 450–3 600 | gpt-oss-120b, Qwen3.8-Flash-Next, Mistral Small 4, Laguna S, Qwen3.5-122B; GLM-5.3-Flash только в 3 бита впритык | M5 Max: gpt-oss-120b 2 537 tok/s prefill / 64,5 decode на 32K; Qwen3.8-27B TTFT 65,5 с на 32K; Qwen3.6-35B-A3B 8-bit TTFT 15,2 с. Spark: Qwen3.8-Flash-Next NVFP4 67,5 tok/s (vLLM + MTP). Strix Halo: gpt-oss-120b prefill 294 на 64K, то есть длинный контекст тянет слабо |
| 192 ГБ x86 | AMD Gorgon Halo (Max+ PRO 495): Bosgame $6 199, GMKtec $6 799, Framework $6 799, Minisforum $7 399 | До 160 ГБ доступно GPU: GLM-5.3-Flash 3–4 бита | ~21 tok/s GLM-5.3-Flash (квант не указан), полоса ~256–273 ГБ/с |
| **GPU-воркстанции** | RTX 5090: рекомендованная цена $1 999, на рынке **$5–10 тыс. и растёт** (Wccftech, 3 ноября; разовое предложение $3 340 на Walmart — исключение); RTX PRO 6000 96 ГБ $13–16 тыс.; 3090 б/у ~$1 200–1 500 | 27–35B на высокой скорости; 4×PRO 6000 тянут GLM-5.3-Flash | 5090: Qwen3.8-27B prefill 3 031 tok/s, decode 59. 4×PRO 6000 Max-Q: GLM-5.3-Flash NVFP4 281 tok/s single-stream, 13 816 tok/s prefill на 32K. 4×3090 с Qwen3.8-Flash-Next: 116–193 tok/s с MTP (данные сообщества) |
| **256–512 ГБ** | M5 Ultra 256 ГБ ~$10 800; 512 ГБ от $22 299 (требует бин 80c, $6 799+) | GLM-5.3-Flash, DeepSeek V4/V4.1-Flash, K2-Horizon, MiniMax (лицензия против) | M5 Ultra 256 ГБ: Qwen3.8-Flash-Next prefill 2 887 / 2 544 (15,5K / 256K), decode 52–143; GLM-5.3-Flash prefill ~1 016 на 61K, decode 28–41, OOM на 256K; DeepSeek V4-Flash decode ~63 |
| **Гибрид CPU+GPU / серверы** | EPYC ≥200–384 ГБ + 1–2 GPU; DGX Station GB300 ~$85–100 тыс. | V4-Flash и V4.1-Flash через ktransformers; Kimi K3.x и V4-Pro только на 8-GPU узлах или 2–4×M5 Ultra через RDMA | ktransformers V4-Flash: 1×5090 + 200 ГБ RAM, 20+ tok/s. V4.1-Flash на EPYC + 5070 Ti: ~38 tok/s, промпт 35K за 29 с (данные сообщества). 4×M5 Ultra: Muse Spark Open 36,7 tok/s |

**Чего не брать:**
- **M6 MacBook Pro и Mac mini M6:** 153–170 ГБ/с, максимум 32 ГБ, TB4.
- **M5 Max с 32-ядерным GPU:** потолок 36 ГБ.
- **DGX Spark 64 ГБ ($4 999):** стоит дороже, чем стартовая цена 128-гигабайтной версии.
- **RTX 5090 по текущим ценам.**
- **Ждать M6 Pro/Max не стоит.** По утечке Gurman от 2026-10-15 их не будет, а M7 Pro/Max выйдут в конце 2027.

**Экономика.** DGX Spark за $6 950 при ~67 tok/s выдаёт ~5,8M токенов в сутки. Через API DeepSeek V4.1-Flash (~$1,2 за 1M выходных токенов, вторичный источник) это ~$7 в день, то есть окупаемость больше двух лет при 100% загрузке. Локальный запуск оправдан ради приватности, отсутствия фильтров провайдера и возможности запускать uncensored-веса, но не ради цены токена.

---

## 7. Инференс-стек

**Выбор движка по тирам:**

| Тир | Основной | Альтернативы | Избегать |
|---|---|---|---|
| Mac 24 ГБ | **llama.cpp `llama-server`** (MIT, без телеметрии; OpenAI + Anthropic `/v1/messages`; prompt cache + checkpoints) | oMLX (Apache; SSD-кэш KV переживает рестарт; обязательно ограничить `--paged-ssd-cache-max-size`) | LM Studio (GUI проприетарный; бандл llama.cpp 2.21–2.28.2 ломает tensor API на M5); Splash (≥36 ГБ); Ollama для Qwen3.6/3.8 |
| Mac 48–128 ГБ | llama.cpp / oMLX; `rec` для Flint | vllm-metal (батчи: 3,64 с против 5,33 у llama.cpp), Ollama MLX | — |
| Mac 256–512 ГБ | MLX / oMLX, llama.cpp | MLX RDMA по TB5 (macOS 26.2+, MLX ≥0.30.1) | pipeline-параллелизм по TCP (по SiliconBench он деградирует) |
| 1 GPU + много RAM | llama.cpp / ik_llama.cpp (`--n-cpu-moe`, `-ot exps=CPU`, `--moe-cache-mib`), ktransformers | ExLlamaV3 + TabbyAPI (TabbyAPI под AGPL) | — |
| Мульти-GPU | vLLM (v0.33) / SGLang (v0.5.23) | — | Забытый `VLLM_NO_USAGE_STATS=1`: статистика использования включена по умолчанию |

**Квантование:**
- KLD относительно BF16 на Qwen3.6-27B (MLX): 8-bit 0,0028; 6-bit 0,0037; **4-bit 0,0227**; NVFP4 0,0325; MXFP4 0,0479; 3-bit 0,0734. На Apple при пост-квантовании affine 4-bit лучше обоих FP4-форматов.
- Независимые агентные замеры:
  - Qwen3.8-27B Q4_K_M не уступает BF16 на TB2.1 (Quesma). UD-Q2_K_XL даёт заметное падение, 1-бит сваливается в случайные ответы.
  - imec, INT4 AWQ против FP8: Qwen3.8-27B 32 и 30 из 64 на SWE-Pro, GLM-5.3-Flash 69 и 69 на DeepSWE.
- **Правила:**
  - ≥4 бита, где позволяет память, ≥5–6 бит для критичных tool calls.
  - На 24 ГБ — 3 бита, это компромисс.
  - KV q8_0 обычно безопасен, но на Metal он не оптимизирован (замечание ggerganov), поэтому сравните с f16.
  - **KV q4_0 портит tool calls** (предупреждение в документации llama.cpp; для Flint: +67% KLD на коде).
  - Flint заметно чувствительнее к квантованию, чем плотные модели.

**Подводные камни парсеров tool calls (состояние на сегодня):**
- **Qwen3.5/3.6/3.8 и Nanbeige в llama.cpp.**
  - Шаблоны маршрутизируются в специализированный парсер Qwen3-Coder (PR #26252, с b10227). Он принимает текст перед `<tool_call>` и tool call, начатый внутри `<think>`. Этим закрыт #20260 (HTTP 500).
  - PR #30557 (10-28) починил whitespace, из-за которого инвалидировался prefix-кэш.
  - Остаточная нестабильность есть: #20837 открыт.
  - **Берите билд ≥ конца октября** (последний b12175).
- **Шаблон Qwen3.8 и Nanbeige** бросает `raise_exception('System message must be at the beginning.')` на любое system- или developer-сообщение не в начале. Claude Code такие сообщения шлёт, поэтому для него нужен `--chat-template-file` из [froggeric/Qwen-Fixed-Chat-Templates](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates) v22.5. OpenCode, Pi и Qwen Code обычно шлют один ведущий system и должны работать на стоковом шаблоне. Это вывод из устройства харнессов, end-to-end не подтверждено.
- **`--jinja` включён по умолчанию** с ноября 2025.
- **`-c` по умолчанию берёт контекст модели** (для Qwen3.8 это 256K), поэтому на 24 ГБ задавайте его явно.
- **Flint:** в llama.cpp нет своего парсера, generic-autoparser не закрывает reasoning на `<tool_call>` (#31000, возможно, только NVFP4). В vLLM используйте `glm47` до слияния `flint`, в SGLang — `--tool-call-parser flint`.
- **Остальные семейства:**
  - DeepSeek V4/V4.1: Jinja-шаблона нет, нужен `encoding/` или deepseek-recipe.
  - Kimi K3.x: возвращать `reasoning_content` + `tool_calls`.
  - gpt-oss: harmony.
  - vLLM: `--enable-auto-tool-choice --tool-call-parser <qwen3_xml | qwen3_coder | glm47 | kimi_k2 | deepseek_v31 | openai | mimo | step5>`, версию vLLM фиксировать.

**Prompt caching (главное для агентов):**
- Prefill — узкое место. Агент перечитывает 20–100K токенов на каждом ходу.
- llama.cpp: `--cache-prompt` (включён), `--cache-ram`, `--ctx-checkpoints`.
- Гибридные модели (DeltaNet) не умеют обрезать recurrent state. Любое изменение начала промпта ведёт к полному перепросчёту. Для Claude Code: `CLAUDE_CODE_ATTRIBUTION_HEADER=0`.
- Системный промпт и схемы инструментов держите стабильными.

**MTP и спекулятивное декодирование:**
- llama.cpp MTP (`--spec-type draft-mtp --spec-draft-n-max 2`) работает только с одним слотом и **замедляет prefill**. На Metal данные противоречивы: старое 13,6-кратное замедление было на неслитом PR, мейнтейнеры сообщают об ускорении.
- В MLX/oMLX MTP помогает: Qwen3.8-27B oQ4e-mtp даёт 28–35 tok/s.
- Для правок кода дешевле `--spec-type ngram-mod`.
- Проверяйте на своей нагрузке.

**Стабильность на Mac:**
- В MLX есть открытый kernel panic `prepare count underflow` (mlx#3186). Похожие отчёты есть и с машин на 24 ГБ: mlx-lm#883 (27B 4-bit падал на 40–50K контекста) и mlx#3346.
- Обходной путь: не выставлять `mx.set_wired_limit` и использовать чанкованный prefill.
- Отчётов о panic в llama.cpp на 24 ГБ M4 Pro не найдено **(не подтверждено)**. Утверждение «Q4_K_M вызвал три паники» в одном блоге относится к пику 19,6 ГБ, выше лимита.
- `iogpu.wired_limit_mb` до 19 456–20 480 работал стабильно в одном тесте с llama.cpp. Сбрасывается после перезагрузки.

---

## 8. Харнессы и фреймворки

**Coding-агенты** (лицензия, состояние, телеметрия):

| Харнесс | Лицензия | Статус | Телеметрия | Комментарий |
|---|---|---|---|---|
| **OpenCode** (anomalyco/opencode) | MIT | v2.2.5, ~225k звёзд | Отдельной настройки не задокументировано; отключить `OPENCODE_DISABLE_AUTOUPDATE`, `_MODELS_FETCH`, `_LSP_DOWNLOAD`, `_DEFAULT_PLUGINS`, `OPENCODE_PURE`, провайдер Zen | Первый ход ~6,9K токенов против ~32,8K у Claude Code. **В v2 `limit.context` обязательно равен `-c`**, иначе по умолчанию 200K и компакция не срабатывает |
| **Pi** (earendil-works/pi) | MIT | v1.5.0 | не найдено | Минимальный промпт: <1K по одному источнику, 1 358 токенов по независимому замеру (цифра «605» не подтверждается). Не спрашивает разрешения на запись и exec, ужесточайте вручную. MCP через `pi-mcp-adapter` |
| **mini-swe-agent** | MIT | v2.4.6 | — | Только bash, от формата tool calls модели не зависит. Его же использует Vals на TB4 |
| **Qwen Code** | Apache-2.0 | v0.26.8 | **`usageStatisticsEnabled` включён по умолчанию** (шлёт в Alibaba RUM) → false | Задать `contextWindowSize`, иначе считает контекст 1M |
| Goose | Apache-2.0 (LF AAIF) | v1.57.0 | opt-in | tool shim для моделей без нативных инструментов |
| Cline | Apache-2.0 | v4.1.26 | **включена по умолчанию** | Compact Prompt для локальных моделей |
| Codex CLI | Apache-2.0 | v0.167 | **аналитика включена по умолчанию** | `--oss`, Ollama `/v1/responses` |
| Crush | FSL-1.1-MIT (не OSI) | v0.100 | метрики включены по умолчанию | нативные провайдеры llamacpp и omlx |
| OpenHands | MIT | v1.37.0 | — | Документация советует Qwen3.6-35B-A3B и Mac от 64 ГБ; монтирование docker.sock даёт контроль над хостом |
| Aider → **cecli** | Apache-2.0 | upstream заглох (v0.86, август 2025) | opt-in | текстовые edit-форматы надёжны с локальными моделями |
| Zed agent | GPL-3.0 | 1.28-pre | отключаемо | ACP: OpenCode и Pi внутри Zed; у Ollama `num_ctx` по умолчанию 4096, поднимайте |
| Claude Code | **проприетарный** | — | по умолчанию включена (`DISABLE_TELEMETRY=1`) | Используется вендорами в собственных evals, но под требование открытости не подходит |
| Мёртвые или проданные | — | Roo Code (архив с 05-15), Void (архив), Plandex (спит), Kilo (куплен Anaconda) | — | — |

**Лучшие пары модель + харнесс:**
- 24 ГБ: Qwen3.6-35B-A3B + OpenCode; Qwen3.8-27B + Qwen Code или Pi для дизайн-сессий; любая модель с нестабильным JSON + mini-swe-agent.
- Сервер: GLM-5.3 + OpenCode (53,6 на AA Coding Agent Index, вторичный источник); Kimi K3.x + Kimi Code или Claude Code.
- Учтите: вендоры дообучают модели под схему Claude Code, в собственном харнессе ждите на 2–10 п.п. меньше.

**Фреймворки для собственного харнесса:**
- smolagents (Apache; CodeAgent пишет действия как Python), Pydantic AI (MIT), LangGraph (MIT), DSPy, Letta.
- Что выключить: в OpenAI Agents SDK трейсинг в OpenAI включён по умолчанию (`OPENAI_AGENTS_DISABLE_TRACING=1`); в CrewAI телеметрия включена (`CREWAI_DISABLE_TELEMETRY=true`, `CREWAI_TRACING_ENABLED=false`); Agno — `AGNO_TELEMETRY=false` (значение по умолчанию не подтверждено).
- AutoGen архивирован, на смену ему пришёл Microsoft Agent Framework.
- **LiteLLM 1.82.7 и 1.82.8 на PyPI были с бэкдором** (март 2026). Фиксируйте версии.

**MCP:**
- Спецификация 2026-07-28: без handshake и сессий, `server/discover`.
- Легаси-клиент с dual-era-сервером работает, а официальные v2 SDK-серверы как раз dual-era. **Не форсируйте `protocol: "2026-07-28"`** в OpenCode, оставьте `legacy` или `auto`.
- Встроенный MCP в llama-server экспериментальный: только stdio, протокол 2024-11-05, deadlock на запросах >1–5 KB (#28723). Подключайте MCP в харнессе.
- Локальный набор серверов: Filesystem, Git, Fetch, Memory (референсные); Playwright MCP (Apache, `--headless`); SearXNG MCP (каноничного нет, смотрите на поддержку); Serena (LSP-навигация, GPL-3.0, SolidLSP под MIT).
- Context7 — облачный сервис, не локальный.

---

## 9. Готовые рецепты

### Рецепт A. MacBook M4 Pro 24 ГБ: быстрый агент (Qwen3.6-35B-A3B) + OpenCode

```bash
# 0. Перед запуском закройте тяжёлые приложения: на 24 ГБ нехватка памяти
#    может подвесить систему вместе со всем, что в ней открыто.
brew install llama.cpp && llama-server --version   # нужен билд от конца октября 2026 или новее (b12175)
mkdir -p ~/models && cd ~/models
pipx install huggingface_hub    # даёт CLI `hf` (способ установки проверьте по документации HF)

# 1. Модель: ровно один файл, не весь репозиторий
hf download unsloth/Qwen3.6-35B-A3B-GGUF Qwen3.6-35B-A3B-UD-IQ3_S.gguf --local-dir ~/models

# 2. Сервер. KV f16 при 20 KiB/токен на 64K стоит ~1,25 GiB.
#    Лимит Metal не поднимаем; только если упрётесь, временно:
#    sudo sysctl iogpu.wired_limit_mb=19456
llama-server -m ~/models/Qwen3.6-35B-A3B-UD-IQ3_S.gguf --alias qwen3.6-35b \
  -c 65536 -fa on --cache-ram 2048 --ctx-checkpoints 64 \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --host 127.0.0.1 --port 8080

# 3. Smoke test: должен вернуться finish_reason "tool_calls"
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
 "model":"qwen3.6-35b","messages":[{"role":"user","content":"Какая погода в Берлине? Используй инструмент."}],
 "tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]}' | jq '.choices[0]'
```

**OpenCode v2.** Установка по README [anomalyco/opencode](https://github.com/anomalyco/opencode). Файл `~/.config/opencode/opencode.jsonc` (схема ключей по [документации v2](https://opencode.ai/v2/docs/models/)):
```jsonc
{ "model": "llamacpp/qwen3.6-35b",
  "providers": { "llamacpp": { "name": "llama.cpp",
    "package": "@opencode/ai/providers/openai-compatible",
    "settings": { "baseURL": "http://127.0.0.1:8080/v1" },
    "models": { "qwen3.6-35b": { "modelID": "qwen3.6-35b",
      "capabilities": { "tools": true, "reasoning": { "supported": true } },
      "compatibility": { "reasoningField": "reasoning_content", "requireReasoning": true },
      "limit": { "context": 65536, "output": 16384 } } } } } }
```
```bash
export OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_DEFAULT_PLUGINS=1
opencode
```
В MCP-серверах оставьте `protocol` по умолчанию (`legacy`). Для маленькой модели можно поставить `codemode: false`.

**Uncensored-вариант A.** Те же флаги, другой файл:
```bash
hf download mradermacher/Qwen3.6-35B-A3B-uncensored-heretic-i1-GGUF \
  Qwen3.6-35B-A3B-uncensored-heretic.i1-IQ3_XS.gguf --local-dir ~/models   # 14,48 ГБ; i1-IQ3_S = 15,25 ГБ
# Сверьте SHA-256 с lfs.sha256 из HF API и сохраните рядом README и LICENSE
```
MLX-альтернативы без цензуры: `zecanard/…abliterix-v2-MLX-2bit-mixed_2_6` (14,93 ГБ) и `frogggias/…Heretic-MLX-oQ2` (13,11 ГБ, происхождение не указано). Это 2 бита, качество ниже. 3-битные MLX-сборки весят 17,8–18,7 ГБ и упираются в лимит.

### Рецепт B. 24 ГБ: архитектор (Qwen3.8-27B), запуск по требованию

```bash
# Сначала остановите сервер рецепта A: обе модели одновременно не помещаются
hf download unsloth/Qwen3.8-27B-GGUF Qwen3.8-27B-UD-IQ4_XS.gguf --local-dir ~/models   # 14,25 ГБ
llama-server -m ~/models/Qwen3.8-27B-UD-IQ4_XS.gguf --alias qwen3.8-27b \
  -c 32768 -fa on -ctk q8_0 -ctv q8_0 --reasoning-format deepseek \
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --host 127.0.0.1 --port 8080
# Для 64K берите UD-Q3_K_XL (13,1 ГБ). Q4_K_M на 24 ГБ не использовать.
```
- **Харнесс:** Qwen Code. В `~/.qwen/settings.json` задайте `privacy.usageStatisticsEnabled: false`, `model.generationConfig.contextWindowSize: 32768`, `context.autoCompactThreshold: 0.6`. Либо Pi с `chat_template_kwargs` (`enable_thinking`, `reasoning_effort`).
- **Claude Code (проприетарный, по желанию):** добавьте к серверу `--chat-template-file froggeric/chat_template.jinja`, затем `ANTHROPIC_BASE_URL=http://127.0.0.1:8080 ANTHROPIC_AUTH_TOKEN=local ANTHROPIC_MODEL=qwen3.8-27b CLAUDE_CODE_ATTRIBUTION_HEADER=0 claude`.
- **Ожидания:** ~11–13 tok/s генерации, холодный промпт на 32K обрабатывается ~4–4,5 минуты. Режим разовых дизайн-ревью, не агентный цикл.

**Uncensored-вариант B:**
- `orcarouter/Qwen3.8-27B-Uncensored-GGUF`, файл IQ3_M (12,77 ГБ). Максимальная готовность отвечать (ASR 82,2%), но 152 из 400 незавершённых thinking. Репозиторий гейтед, нужны логин и согласие.
- Либо `mradermacher/Qwen3.8-27B-heretic-ara-i1-GGUF`, файл i1-IQ3_M (12,9 ГБ). Меньше зацикливаний (61 из 400), лучший HumanEval.
- Для обоих: недетерминированный сэмплинг, лимит токенов на ход, ограничение thinking-бюджета.
- **Диск:** A-uncensored + B-uncensored ≈ 14,5 + 12,8 ≈ 27 ГБ. Если внутренний диск небольшой, архив моделей держите на внешнем TB5 SSD (`HF_HOME=/Volumes/SSD/hf`).

### Рецепт C. Mac mini M5 Pro 64 ГБ

```bash
# Flint на rec (Apache-2.0; требует M4/M5 Pro/Max с ≥48 ГБ и ~30 ГБ диска). Установка по README recursive-oss/rec;
# сервер OpenAI/Anthropic-совместимый на :11500
# Классический вариант на llama.cpp: архитектор и агент одновременно в памяти
llama-server -hf unsloth/Qwen3.8-27B-GGUF:Q8_0 -c 131072 -fa on --port 8081 &
llama-server -hf unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q6_K_XL --no-mmproj -c 131072 -fa on --port 8080 &
# Ripple-65B: llama.cpp ≥ b12167, AtomicChat/Ripple-65B-Preview-GGUF Q4_K_M (40,4 ГБ), ~7 tok/s
```
- Харнесс OpenCode с двумя провайдерами: plan-агент на :8081, build-агент на :8080.
- Квант Q6_K_XL для Qwen3.6 подставлен по логике линейки, перед загрузкой сверьте точное имя файла в репозитории.
- **Uncensored:** `electroglyph/flint-uncensored` (7/100 отказов) или dima6312 MLX-4bit; llmfan46 Qwen3.6 Heretic Q6; Luni Nanbeige Heretic IQ4.

### Рецепт D. Mac Studio M5 Max 128 ГБ

```bash
llama-server -hf ggml-org/gpt-oss-120b-GGUF -c 131072 -fa on --host 127.0.0.1 --port 8080
# Upstream llama.cpp (tensor API на M5 удваивает prefill: 1 833 против 877 tok/s); бандл LM Studio его ломает
```
- Альтернатива-архитектор: Qwen3.8-Flash-Next IQ4_XS (93,7 ГБ). Лицензия L4, GGUF теряет MTP; MLX + MTP даёт ~73–90 tok/s.
- **Uncensored:** `ArliAI/gpt-oss-120b-Derestricted`: UGI W/10 9,2 при NatInt 35,70, выше стока. Есть GGUF Calandracas и Ollama `gurubot/gpt-oss-derestricted`.
- Нативно мало отказов и нет политического крена: Mistral Small 4 119B (Apache, SpeechMap 90,9%).

### Рецепт E. M5 Ultra 256–512 ГБ или EPYC + GPU (MIT-фронтир)

- **GLM-5.3-Flash:** MLX/oMLX на M5 Ultra (prefill ~1 000 tok/s на 61K) или GGUF Unsloth через их llama.cpp-PR. На NVIDIA: vLLM с `--tool-call-parser glm47`, либо ktransformers.
- **DeepSeek V4.1-Flash-1017:** Unsloth GGUF (нужен их PR, архитектура `deepseek41`), tool calls через deepseek-recipe. ktransformers на EPYC + 1–2 GPU даёт ~38–54 tok/s (данные сообщества).
- **Uncensored:** dealignai `DeepSeek-V4.1-Flash-1017-UNCENSORED-FP8`, orcarouter abliterated GGUF. Скачиваемых abliterated-сборок GLM-5.3-Flash не найдено.

---

## 10. Риски и как проверить самому

**Мини-протокол оценки.** Полдня на модель, три ориентира: харнесс как у вас, квант как у вас, сравнение стоковой и uncensored-сборки в одинаковых условиях.

1. **Железо:**
   - `llama-bench -m <gguf> -fa 1 -p 512 -n 128 -d 0,8192,32768` — prefill на глубине, это и есть ваши агентные ходы.
   - `-p 8192,32768 -n 0 -ctk f16` против `-ctk q8_0` — проверка KV на Metal.
   - Параллельно следите за `memory_pressure -Q` и `vm_stat | grep wired`.
   - **Правило:** если 27B даёт ≥300 tok/s на pp32768 (это противоречило бы всем данным), она может быть исполнителем. Иначе исполнителем остаётся MoE.
2. **Tool calls:**
   - 30–50 сценариев из вашего домена: одиночный вызов, параллельные вызовы, вызов после длинного reasoning, вложенные объекты в аргументах, позднее system-сообщение.
   - Метрики: валидность JSON и XML, правильное имя инструмента (галлюцинации имён), `finish_reason`, повторные вызовы. Считайте ошибки, а не только pass@1.
   - Внешний прокси: BFCL v4 и подмножество tau2 против llama-server.
3. **Агентные задачи:**
   - 10–20 реальных тикетов из ваших репозиториев: баг, фича в 3+ файлах, миграция схемы, «спроектируй харнесс X».
   - Каждый прогон по 3 раза с temperature > 0. Считайте долю решённых, время и токены.
4. **Uncensored-сборки:** те же пункты 2–3 плюс 20 промптов из вашей «серой зоны» (security, RE). Записывайте долю пустых и зацикленных ответов и долю незакрытых `<think>`.
5. **Политика:** 10 геополитических вопросов. Сравните с Mistral/Gemma, если ресёрч касается этой области.

**Известные сбои:**
- **Петли и незакрытый thinking.** У abliterated 15–45% на вредных промптах (temperature 0). У Flint 19 из 100 упирались в лимит 8 192 токенов. Лечится лимитом токенов, `presence_penalty`, отказом от greedy-сэмплинга и бюджетом thinking.
- **Сломанные tool calls.** Вызов внутри reasoning (OpenCode v2: `reasoningField`), текст до `<tool_call>` (решено в llama.cpp, но держите билд свежим), позднее system-сообщение у Qwen3.8 и Nanbeige, у Ollama не тот парсер (исторически Hermes вместо Qwen-XML).
- **Деградация на длинном контексте.** Независимых long-context замеров для малых моделей 2026 года нет. YaRN до 1M «может ухудшить работу на коротких текстах», включайте его только при необходимости. Делайте компакцию каждые N ходов.
- **Тихие ловушки:**
  - Ollama по умолчанию 4K контекста (4K при <24 ГиБ VRAM). Теги `:cloud` выглядят локальными, но работают удалённо.
  - В OpenCode v2 по умолчанию стоит 200K, без `limit.context` компакция не срабатывает.
  - Qwen Code по умолчанию считает контекст 1M.
  - Устройство может «выдохнуться» на OOM без явной ошибки.
- **Фабрикации.** Flint в тестах писал `PLACEHOLDER` и рапортовал об успехе. Проверяйте артефакты, а не отчёт агента.
- **Безопасность:** встроенные `--tools`/`--agent` в llama-server и MCP-дочерние процессы фактически дают RCE. Привязывайте сервер к 127.0.0.1, ограничьте `--cors-origins`, у Pi включите подтверждения.
- **Дистрибуция:** HF удаляет отдельные uncensored-репозитории. Зеркальте файлы вместе с README и LICENSE, проверяйте `lfs.sha256`.

**Что перепроверять ежемесячно:**
- AA v5 (open-source и small), Vals TB4, ProgramBench, SkillsBench, Scale MCP-Atlas, а также SWE-rebench, если он оживёт (последнее обновление 07-01).
- Появились ли строки UGI для Qwen3.8, Nanbeige, Flint и GLM-5.3.
- Релизы llama.cpp: парсер Flint, #20837, MCP.
- Heretic v2 и сборки на ARA; GGUF от SolsticeAI.
- Ollama: загрузка mmproj для qwen35, порог MLX >32 ГБ.
- Статус OpenMDW-1.1 в OSI; появление LICENSE-файла в MiMo; изменения в лицензиях Kimi и Qwen.
- Выход Qwen3.9 или Qwen3.8-MoE (35B-A3B), Nanbeige 4.4, Flint 1.1, финального Ripple (лицензия может поменяться).
- Цены на память, RTX 5090 и DGX Spark.

---

## 11. Источники

**Модели (карточки и лицензии):**
- Qwen: [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B), [шаблон](https://huggingface.co/Qwen/Qwen3.8-27B/raw/main/chat_template.jinja), [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next), [Qwen3.8-2.4T LICENSE](https://huggingface.co/Qwen/Qwen3.8-2.4T-A95B/blob/main/LICENSE), [Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B), [Qwen3.6-27B](https://huggingface.co/Qwen/Qwen3.6-27B)
- Unsloth GGUF: [Qwen3.8-27B](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF), [Qwen3.6-35B-A3B](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF), [Flint](https://huggingface.co/unsloth/flint-GGUF), [DeepSeek V4.1-Flash-1017](https://huggingface.co/unsloth/DeepSeek-V4.1-Flash-1017-GGUF)
- Kimi: [K3.1 Pro](https://huggingface.co/moonshotai/Kimi-K3.1-Pro), [LICENSE](https://huggingface.co/moonshotai/Kimi-K3.1-Pro/blob/main/LICENSE), [K3](https://huggingface.co/moonshotai/Kimi-K3), [TNW о вырезанных кибер-данных](https://thenextweb.com/news/moonshot-kimi-k3-1-pro-open-weight-cyber)
- DeepSeek: [V4.1-Flash-1017](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017), [V4-Pro-0813](https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro-0813)
- GLM: [GLM-5.3](https://huggingface.co/zai-org/GLM-5.3), [GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash)
- MiMo: [MiMo-V2.6-Pro-RL](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Pro-RL)
- Meta: [Muse Glimmer 30B](https://huggingface.co/meta-models/Muse-Glimmer-30B), [USAGE_POLICY](https://huggingface.co/meta-models/Muse-Glimmer-30B/blob/main/USAGE_POLICY.md), [Muse Spark Open](https://research.meta.ai/blog/muse-spark-open)
- Google: [Gemma 4 31B](https://huggingface.co/google/gemma-4-31B-it), [лицензия Gemma 4](https://ai.google.dev/gemma/docs/gemma_4_license), [EmbeddingGemma 2](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2/)
- Прочие локальные: [Nanbeige4.3-33B](https://huggingface.co/Nanbeige/Nanbeige4.3-33B), [Flint](https://huggingface.co/RecursiveSI/flint), [rec](https://github.com/recursive-oss/rec), [Ripple-65B](https://huggingface.co/ricursiveAI/Ripple-65B-Preview), [gpt-oss-20b](https://huggingface.co/openai/gpt-oss-20b), [Laguna XS 2.1](https://huggingface.co/poolside/Laguna-XS-2.1)
- NVIDIA: [Nemotron 3 Ultra](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-BF16), [NVIDIA Open Model License (с guardrail-оговоркой)](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/), [Nemotron Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license/)
- Прочие frontier: [MiniMax M3 LICENSE](https://huggingface.co/MiniMaxAI/MiniMax-M3/raw/main/LICENSE), [Beam](https://reflection.ai/blog/introducing-beam), [Inkling-Small](https://thinkingmachines.ai/model-card/inkling-small/), [K2-Horizon](https://huggingface.co/IFM/K2-Horizon-375B-A23B)
- Fully open: [Olmo Hybrid](https://allenai.org/blog/olmohybrid), [Olmo 3](https://allenai.org/blog/olmo3), [SERA](https://allenai.org/blog/open-coding-agents), [OpenMDW-1.1](https://raw.githubusercontent.com/OpenMDW/OpenMDW/refs/heads/main/1.1/LICENSE.OpenMDW-1.1), [OSI review](https://lists.opensource.org/pipermail/license-review_lists.opensource.org/2026-August/006125.html), [AA Openness Index](https://artificialanalysis.ai/evaluations/artificial-analysis-openness-index)

**Независимые бенчмарки:**
- Artificial Analysis: [Intelligence Index v5](https://artificialanalysis.ai/articles/artificial-analysis-intelligence-index-v5), [open-source](https://artificialanalysis.ai/models/open-source), [small](https://artificialanalysis.ai/models/open-source/small), [лидерборд](https://artificialanalysis.ai/leaderboards/models)
- Vals: [Terminal-Bench 4.0](https://www.vals.ai/benchmarks/terminal-bench-4), [ProgramBench](https://www.vals.ai/benchmarks/programbench), [SkillsBench](https://www.vals.ai/benchmarks/skillsbench)
- [Scale MCP-Atlas](https://labs.scale.com/leaderboard/mcp_atlas), [SWE-rebench](https://swe-rebench.com/), [Epoch: разрыв open/closed](https://epoch.ai/data-insights/open-closed-eci-gap), [OpenAI о SWE-bench Verified](https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/)
- Квантование и инструменты: [imec](https://aistack.imec-int.com/blog/quantization), [Quesma](https://quesma.com/blog/qwen38-27b-quantizations-benchmarked/), [квантование и tool calls, arXiv 2607.27275](https://arxiv.org/abs/2607.27275), [MiaAI tool-eval](https://github.com/MiaAI-Lab/Best-Local-Model_Agentic-Workflows_2026)

**Цензура и abliteration:**
- Рейтинги отказов: [UGI CSV](https://huggingface.co/spaces/DontPlanToEnd/UGI-Leaderboard/resolve/main/ugi-leaderboard-data.csv), [SpeechMap](https://speechmap.ai/models/)
- Abliteration: [Abliterlitics Qwen3.8-27B](https://abliterlitics.dev/models/qwen38-27b/), [Heretic](https://github.com/p-e-w/heretic), [миграция на v2](https://github.com/p-e-w/heretic/blob/master/docs/migration_v1_to_v2.md), [arXiv 2512.13655](https://arxiv.org/html/2512.13655v2), [grimjim norm-preserving](https://huggingface.co/blog/grimjim/norm-preserving-biprojected-abliteration)
- Политическая цензура: [Aleph Alpha](https://aleph-alpha.com/en/blog/training-on-the-party-line/), [lab.cloud](https://lab.cloud/research/uncensoring-is-not-unlearning/), [Schneier: Qwen3-Coder](https://www.schneier.com/blog/archives/2026/10/bias-in-qwen3-coder-model.html)
- Отказы в security-задачах: [Scale AI Defensive Refusal](https://arxiv.org/html/2603.01246)
- Удаления с HF: [pillitteri](https://pasqualepillitteri.it/en/news/27102/hugging-face-bans-uncensored-models-kimi-k27-code)
- Сборки для 24 ГБ: [llmfan46 Qwen3.6 Heretic](https://huggingface.co/llmfan46/Qwen3.6-35B-A3B-uncensored-heretic), [mradermacher i1 GGUF](https://huggingface.co/mradermacher/Qwen3.6-35B-A3B-uncensored-heretic-i1-GGUF), [orcarouter Qwen3.8 GGUF](https://huggingface.co/orcarouter/Qwen3.8-27B-Uncensored-GGUF), [trohrbaugh ARA i1](https://huggingface.co/mradermacher/Qwen3.8-27B-heretic-ara-i1-GGUF), [ArliAI gpt-oss-120b-Derestricted](https://huggingface.co/ArliAI/gpt-oss-120b-Derestricted)

**Движки и tool calling:**
- llama.cpp: [server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md), [PR #26252](https://github.com/ggml-org/llama.cpp/pull/26252), [#27107](https://github.com/ggml-org/llama.cpp/issues/27107), [#20003](https://github.com/ggml-org/llama.cpp/issues/20003), [#31000](https://github.com/ggml-org/llama.cpp/issues/31000), [Anthropic API](https://huggingface.co/blog/ggml-org/anthropic-messages-api-in-llamacpp)
- Шаблоны: [froggeric fixed templates](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates)
- MLX: [oMLX](https://github.com/jundot/omlx), [mlx-lm](https://github.com/ml-explore/mlx-lm), [mlx#3186](https://github.com/ml-explore/mlx/issues/3186), [mlx-lm#883](https://github.com/ml-explore/mlx-lm/issues/883), [vllm-metal](https://vllm.ai/blog/2026-09-22-vllm-metal-v0-28-0)
- vLLM: [tool calling](https://docs.vllm.ai/en/latest/features/tool_calling.html), [usage stats](https://docs.vllm.ai/en/latest/usage/usage_stats.html)
- Ollama: [Anthropic compat](https://docs.ollama.com/api/anthropic-compatibility), [длина контекста](https://docs.ollama.com/context-length)
- Прочее: [ktransformers](https://github.com/kvcache-ai/ktransformers), [Unsloth Qwen3.6](https://unsloth.ai/docs/models/qwen3.6)

**Харнессы и MCP:**
- OpenCode: [репозиторий](https://github.com/anomalyco/opencode), [v2 models](https://opencode.ai/v2/docs/models/), [v2 MCP](https://opencode.ai/v2/docs/mcp-servers/), [накладные расходы токенов против Claude Code](https://systima.ai/blog/claude-code-vs-opencode-token-overhead)
- Агенты: [mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent), [Qwen Code](https://github.com/QwenLM/qwen-code), [Goose](https://github.com/aaif-goose/goose), [OpenHands local LLMs](https://docs.openhands.dev/openhands/usage/llms/local-llms), [Pi](https://huggingface.co/docs/hub/agents-local)
- MCP: [спецификация 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/changelog), [Playwright MCP](https://github.com/microsoft/playwright-mcp), [Serena](https://github.com/oraios/serena)
- Эмбеддинги и реранкеры: [Qwen3-Embedding](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B), [Qwen3-Reranker](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B)
- Безопасность: [компрометация LiteLLM](https://www.itpro.com/security/litellm-pypi-compromise-everything-we-know-so-far)

**Железо и цены:**
- Замеры на 24 ГБ и M4 Pro: [Halfpenny, M4 Pro 24 ГБ](https://halfpennymac.com/qwen38-27b-m4-mac-mini-benchmark), [kartit, 24 ГБ MacBook](https://www.kartit.net/blog/qwen38-27b-24gb-macbook), [oMLX Qwen3.8-27B M4 Pro](https://omlx.ai/benchmarks/performance/m2ege5kz), [oMLX Qwen3.6 M4 Pro](https://omlx.ai/benchmarks/performance/bo6b1jws), [oMLX gpt-oss-20b](https://omlx.ai/benchmarks/74t9m0ho)
- Старшие тиры: [MacStories M5 Ultra](https://www.macstories.net/stories/m5-ultra-mac-studio-review-the-dream-mac-for-local-ai-agents/), [Flint на M5 Pro](https://github.com/nace-ai/kapitsa/blob/main/bench/results/2026-10-22-flint-m5pro/README.md), [Apple M5 и MLX](https://machinelearning.apple.com/research/exploring-llms-mlx-m5), [M5 Max: tensor API и LM Studio](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2040)
- Анонсы Apple: [M6 MacBook Pro](https://www.apple.com/newsroom/2026/10/apple-introduces-the-new-14-inch-macbook-pro-with-m6/), [полоса M6](https://www.macrumors.com/2026/10/27/m6-14-inch-macbook-pro-memory-bandwidth-split/), [Gurman о M7](https://www.macrumors.com/2026/10/15/macbook-pro-m7-late-2027/), [Mac mini и Studio M5](https://www.apple.com/newsroom/2026/09/the-new-mac-mini-and-mac-studio-are-available-today/)
- Цены: [DGX Spark](https://hwbusters.com/news/nvidia-dgx-spark-64gb-arrives-at-4999-as-the-128gb-model-jumps-to-6950/), [RTX 5090, ноябрь](https://wccftech.com/nvidia-rtx-50-gpus-see-a-massive-price-increase-in-november/), [Gorgon Halo](https://videocardz.com/newz/first-amd-gorgon-halo-pc-with-max-pro-495-launches-at-7399-comes-with-192gb-of-memory), [Strix Halo бенчмарки](https://github.com/hogeheer499-commits/strix-halo-guide/blob/main/BENCHMARKS.md)
- Хранилище: [Ollama FAQ (OLLAMA_MODELS)](https://docs.ollama.com/faq), [переменные HF](https://huggingface.co/docs/huggingface_hub/package_reference/environment_variables)