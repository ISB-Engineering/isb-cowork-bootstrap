# isb-cowork-bootstrap

Один PowerShell-скрипт — все скиллы Claude Cowork на ПК сотрудника ИСБ.

## Идея

- Скиллы Cowork — это просто папки в `%USERPROFILE%\.claude\skills\<имя>\`. Cowork подхватывает их автоматически.
- Этот репо хранит `manifest.json` со списком скиллов и **bundle'ами по ролям** (owner, sales, service, finance, hr, supply, install, design, planning, plus dev).
- `install.ps1` принимает роли — клонирует нужные скиллы из их репозиториев и кладёт в `.claude/skills`. Регистрирует хук автообновления.
- Обновление = тот же скрипт перезапускается из хука Cowork при каждом старте.

## Кому что ставится

| Bundle | Что включает |
|---|---|
| `base` | методические минимум: brainstorming, writing-plans, verification-before-completion (входит во все остальные) |
| `owner` | base + contract-review + npa-monitor |
| `sales` | base (пока; sales-secretary и client-card-voice добавим после интервью с Александрой) |
| `service`, `finance`, `hr`, `supply`, `install`, `design`, `planning` | base (заготовки, наполняются по мере появления агентов) |
| `dev` | всё методическое + Vercel React/Composition/Transitions + Supabase + Web Design Guidelines + Anthropic Superpowers (TDD, debugging, code review, и т.п.) |

Бандл может ссылаться на другой через `@base` (как наследование).

## Установка на ПК сотрудника

**Что нужно один раз:**
1. Claude Cowork установлен.
2. Git for Windows установлен (https://git-scm.com/download/win).
3. У сотрудника есть доступ к репо `ISB-Engineering` на GitHub (приватные репо требуют `gh auth login`).

**Команда установки (запускается IT-сотрудником):**

```powershell
# Для Юрия (владелец + dev)
iwr -UseBasicParsing https://raw.githubusercontent.com/ISB-Engineering/isb-cowork-bootstrap/main/install.ps1 -OutFile $env:TEMP\install-isb.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-isb.ps1 -Roles owner -IncludeDev

# Для Александры (продажи)
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-isb.ps1 -Roles sales

# Комбинированная роль (владелец + финансы + HR)
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-isb.ps1 -Roles owner,finance,hr -IncludeDev
```

После установки сотруднику ничего делать не нужно. При каждом старте Claude Cowork хук автоматически перезапускает `install.ps1 -Silent` и подтягивает обновления.

## Если что-то пошло не так

| Симптом | Что делать |
|---|---|
| `git: not found` | Установить Git for Windows |
| `Не удалось скачать manifest.json` | Проверить интернет; если GitHub доступен из браузера, проверить `gh auth status` |
| `Путь 'skills/X' не найден` | Скилл переехал у вендора — обновить путь в `manifest.json` |
| Скилл установился, но Cowork его не видит | Перезапустить Cowork; проверить что `%USERPROFILE%\.claude\skills\<имя>\SKILL.md` существует |
| Сотрудник уволился / нужно убрать скиллы | `Remove-Item -Recurse $env:USERPROFILE\.claude\skills\*` (удалит ВСЕ скиллы — будь осторожен) |

## Добавление нового скилла в каталог

1. PR в этот репо: добавить запись в `manifest.skills` (с `url`, `path`, `ref`) и в нужный бандл `manifest.bundles`.
2. После merge — у всех сотрудников при следующем запуске Cowork скилл подтянется автоматически (благодаря хуку).

## Удаление скилла

1. PR удаляет запись из `manifest.json`.
2. **Внимание:** `install.ps1` не удаляет старые скиллы автоматически — он только ставит то что в манифесте. Если нужно жёстко вычистить — добавить в скрипт логику «всё что не в manifest — удалить». Пока не делаем, чтобы не задеть личные скиллы сотрудников (например `skill-factory`).

## Безопасность

- Все вендорские скиллы тянутся с **публичных** GitHub-репо (`obra/superpowers`, `vercel/vercel-plugin`, `supabase-community/supabase-plugin`). Никаких токенов на их клонирование не нужно.
- Наши собственные (`isb-agents`) — приватный репо. Сотрудник должен быть в org `ISB-Engineering` и аутентифицирован (`gh auth login`).
- Секреты (Bitrix-токены, API-ключи) **не лежат в скиллах**. Они идут через MCP-конфиги (см. `docs/mcp/isbaza_mcp_contract.md` в `isb-agents`).

## Текущий статус

- v0.1 (2026-05-19): первая рабочая версия. **Требует тестового прогона** на ПК Юрия перед раскаткой на команду.
- Bundles `service`, `finance`, `hr`, `supply`, `install`, `design`, `planning` — содержат только `base`, наполнятся когда появятся карточки агентов в `isb-agents`.
