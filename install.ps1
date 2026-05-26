#Requires -Version 5.1
<#
.SYNOPSIS
  Устанавливает скиллы Claude Cowork для сотрудника ИСБ по ролям.

.DESCRIPTION
  Скиллы устанавливаются как локальный Cowork-плагин `isb-cowork` в
  %USERPROFILE%\.claude\plugins\local\isb-cowork\. Регистрируется в локальном
  marketplace user-local — после перезапуска Cowork скиллы видны в окне
  Settings → Skills → Personal skills (с переключателем on/off).

  Идемпотентный: можно запускать многократно. При следующем запуске Cowork
  хук SessionStart (если не -NoAutoUpdate) перезапускает этот скрипт тихо
  и подтягивает свежие версии скиллов из Git.

.PARAMETER Roles
  Список ролей: owner, sales, service, finance, hr, supply, install, design, planning.

.PARAMETER IncludeDev
  Дополнительно поставить bundle 'dev' (методические + Vercel + Supabase).

.PARAMETER NoAutoUpdate
  Не регистрировать SessionStart хук. Только разовая установка.

.PARAMETER Silent
  Минимум вывода. Используется при автообновлении из хука.

.PARAMETER ManifestPath
  Путь к локальному manifest.json. Если не задан — скрипт клонирует bootstrap-репо.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string[]]$Roles,

  [switch]$IncludeDev,
  [switch]$NoAutoUpdate,
  [switch]$Silent,

  [string]$ManifestUrl  = "https://raw.githubusercontent.com/ISB-Engineering/isb-cowork-bootstrap/main/manifest.json",
  [string]$ManifestPath = "",
  [string]$PluginDir    = (Join-Path $env:USERPROFILE ".claude\plugins\local\isb-cowork"),
  [string]$LocalMarketplaceFile = (Join-Path $env:USERPROFILE ".claude\plugins\local\.claude-marketplace\marketplace.json"),
  [string]$LegacySkillsDir = (Join-Path $env:USERPROFILE ".claude\skills"),
  [string]$CacheDir     = (Join-Path $env:TEMP "isb-cowork-cache"),
  [string]$SettingsPath = (Join-Path $env:USERPROFILE ".claude\settings.json"),
  [string]$CoworkSkillsPluginRoot = (Join-Path $env:APPDATA "Claude\local-agent-mode-sessions\skills-plugin"),
  [string]$IsbSkillPrefix = "isb-"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Invoke-Git {
  param([string[]]$GitArgs)
  $output = & git @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE): $output"
  }
}

# PowerShell 5.1's Set-Content -Encoding UTF8 пишет с BOM (﻿).
# Cowork (Electron/Node.js) парсит JSON через JSON.parse, который падает на BOM —
# поэтому пишем UTF-8 БЕЗ BOM через .NET API.
function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Write-Info($msg) {
  if (-not $Silent) { Write-Host "[isb-cowork] $msg" -ForegroundColor Cyan }
}
function Write-Done($msg) {
  if (-not $Silent) { Write-Host "[isb-cowork] $msg" -ForegroundColor Green }
}
function Write-Warn2($msg) {
  Write-Host "[isb-cowork] $msg" -ForegroundColor Yellow
}

# --- 1. Pre-flight ---

# Защита от ситуации, когда несколько ролей пришли одной строкой через запятую
# (так бывает при кросс-процесс вызовах через Start-Process -ArgumentList).
if ($Roles.Count -eq 1 -and $Roles[0] -match ',') {
  $Roles = $Roles[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

Write-Info "Старт. Роли: $($Roles -join ', ')$(if ($IncludeDev) { ' + dev' })"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "Git не найден. Установите Git (https://git-scm.com/download/win) и повторите."
}

$PluginSkillsDir = Join-Path $PluginDir "skills"
$PluginManifestDir = Join-Path $PluginDir ".claude-plugin"

New-Item -ItemType Directory -Force -Path $PluginSkillsDir   | Out-Null
New-Item -ItemType Directory -Force -Path $PluginManifestDir | Out-Null
New-Item -ItemType Directory -Force -Path $CacheDir          | Out-Null

# --- 2. Load manifest ---

if ($ManifestPath -and (Test-Path $ManifestPath)) {
  Write-Info "Читаю локальный manifest: $ManifestPath"
  try {
    $manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    throw "Не удалось прочитать manifest.json: $($_.Exception.Message)"
  }
} else {
  $bootstrapRepoDir = Join-Path $CacheDir "ISB-Engineering_isb-cowork-bootstrap"
  Write-Info "Получаю manifest.json из ISB-Engineering/isb-cowork-bootstrap"
  try {
    if (Test-Path (Join-Path $bootstrapRepoDir ".git")) {
      Invoke-Git @("-C", $bootstrapRepoDir, "fetch", "--depth", "1", "--quiet", "origin", "main")
      Invoke-Git @("-C", $bootstrapRepoDir, "reset", "--hard", "--quiet", "FETCH_HEAD")
    } else {
      Invoke-Git @("clone", "--depth", "1", "--quiet", "https://github.com/ISB-Engineering/isb-cowork-bootstrap.git", $bootstrapRepoDir)
    }
  } catch {
    throw "Не удалось получить manifest.json. Проверь интернет-соединение. $($_.Exception.Message)"
  }
  $localManifest = Join-Path $bootstrapRepoDir "manifest.json"
  if (-not (Test-Path $localManifest)) { throw "manifest.json не найден после клонирования: $localManifest" }
  $manifest = Get-Content $localManifest -Raw -Encoding UTF8 | ConvertFrom-Json
}

# --- 3. Resolve bundles -> skills ---

function Resolve-Bundle($bundleName, $visited) {
  if ($visited -contains $bundleName) { return @() }
  $visited += $bundleName
  if (-not $manifest.bundles.$bundleName) {
    throw "Бандл '$bundleName' не найден в manifest.json. Доступные: $($manifest.bundles.PSObject.Properties.Name -join ', ')"
  }
  $result = @()
  foreach ($item in $manifest.bundles.$bundleName) {
    if ($item.StartsWith("@")) {
      $result += Resolve-Bundle $item.Substring(1) $visited
    } else {
      $result += $item
    }
  }
  return $result
}

$skillsToInstall = @()
foreach ($role in $Roles) {
  $skillsToInstall += Resolve-Bundle $role @()
}
if ($IncludeDev) {
  $skillsToInstall += Resolve-Bundle "dev" @()
}
$skillsToInstall = $skillsToInstall | Sort-Object -Unique

Write-Info "К установке: $($skillsToInstall.Count) скиллов"

# --- 4. Install each skill into the plugin folder ---

$succeeded = @()
$failed    = @()

foreach ($skillName in $skillsToInstall) {
  $spec = $manifest.skills.$skillName
  if (-not $spec) {
    Write-Warn2 "Скилл '$skillName' не описан в manifest.skills — пропускаю"
    continue
  }

  $repoUrl  = $spec.url
  $subPath  = $spec.path
  $ref      = if ($spec.ref) { $spec.ref } else { "main" }
  $repoSafe = ($repoUrl -replace "https://github.com/", "" -replace "\.git$", "" -replace "/", "_")
  $repoDir  = Join-Path $CacheDir $repoSafe
  $skillDir = Join-Path $PluginSkillsDir $skillName

  try {
    # Clone or update repo cache
    if (-not (Test-Path (Join-Path $repoDir ".git"))) {
      Write-Info "Клонирую $repoUrl @ $ref"
      Invoke-Git @("clone", "--depth", "1", "--quiet", "--branch", $ref, $repoUrl, $repoDir)
    } else {
      Write-Info "Обновляю $repoSafe @ $ref"
      Invoke-Git @("-C", $repoDir, "fetch", "--depth", "1", "--quiet", "origin", $ref)
      Invoke-Git @("-C", $repoDir, "reset", "--hard", "--quiet", "FETCH_HEAD")
    }

    $srcDir = Join-Path $repoDir $subPath
    if (-not (Test-Path $srcDir)) {
      throw "Путь '$subPath' не найден в репозитории $repoUrl"
    }

    if (Test-Path $skillDir) {
      Remove-Item -Recurse -Force $skillDir
    }
    Copy-Item -Recurse -Force $srcDir $skillDir

    # Миграция: если этот же скилл лежит в старом месте ~/.claude/skills/<имя>/,
    # удаляем его — новая версия теперь в плагине.
    $legacyPath = Join-Path $LegacySkillsDir $skillName
    if (Test-Path $legacyPath) {
      Remove-Item -Recurse -Force $legacyPath
      Write-Info "  миграция: удалена старая копия $skillName из ~/.claude/skills/"
    }

    $succeeded += $skillName
    Write-Done "OK: $skillName"
  } catch {
    $failed += [pscustomobject]@{ Name = $skillName; Error = $_.Exception.Message }
    Write-Warn2 "FAIL: $skillName — $($_.Exception.Message)"
  }
}

# --- 5. Write plugin.json manifest ---

$pluginManifestPath = Join-Path $PluginManifestDir "plugin.json"
$pluginManifest = [PSCustomObject]@{
  name        = "isb-cowork"
  description = "AI-скиллы для сотрудников ИСБ Инжиниринг: бизнес-агенты (проверка договоров, мониторинг НПА) и помощники разработки. Управляется через ISB-Engineering/isb-cowork-bootstrap."
  version     = "0.5.0"
  author      = [PSCustomObject]@{
    name  = "ISB Engineering"
    email = "info@isb-engineering.kz"
  }
}
Write-Utf8NoBom -Path $pluginManifestPath -Content ($pluginManifest | ConvertTo-Json -Depth 10)

Write-Info "Записан plugin.json: $pluginManifestPath"

# --- 6. Register plugin in user-local marketplace ---

$marketplaceDir = Split-Path $LocalMarketplaceFile -Parent
New-Item -ItemType Directory -Force -Path $marketplaceDir | Out-Null

$mp = $null
if (Test-Path $LocalMarketplaceFile) {
  try {
    $mp = Get-Content $LocalMarketplaceFile -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Write-Warn2 "marketplace.json повреждён — пересоздаю"
    $mp = $null
  }
}

if ($null -eq $mp) {
  $mp = [PSCustomObject]@{
    '$schema'   = "https://anthropic.com/claude-code/marketplace.schema.json"
    name        = "user-local"
    description = "Персональные плагины и скиллы пользователя"
    owner       = [PSCustomObject]@{ name = $env:USERNAME }
    plugins     = @()
  }
}

# Найти или создать запись isb-cowork
$ourPlugin = $null
if ($mp.plugins) {
  $ourPlugin = @($mp.plugins) | Where-Object { $_.name -eq "isb-cowork" } | Select-Object -First 1
}

$newEntry = [PSCustomObject]@{
  name        = "isb-cowork"
  description = "AI-скиллы для сотрудников ИСБ Инжиниринг (бизнес-агенты + dev-помощники)"
  source      = "../isb-cowork"
  category    = "business"
}

if ($ourPlugin) {
  # Обновляем существующую запись
  $newPlugins = @()
  foreach ($p in $mp.plugins) {
    if ($p.name -eq "isb-cowork") {
      $newPlugins += $newEntry
    } else {
      $newPlugins += $p
    }
  }
  $mp.plugins = $newPlugins
} else {
  # Добавляем новую запись
  $mp.plugins = @(@($mp.plugins) + $newEntry) | Where-Object { $_ -ne $null }
}

Write-Utf8NoBom -Path $LocalMarketplaceFile -Content ($mp | ConvertTo-Json -Depth 10)
Write-Info "Зарегистрирован в локальном marketplace: $LocalMarketplaceFile"

# --- 7. Register in Cowork UI (Settings → Skills → Personal skills) ---
# Cowork хранит UI-видимые скиллы в собственной директории с GUID-ами:
#   %APPDATA%\Claude\local-agent-mode-sessions\skills-plugin\<workspace>\<plugin>\
# Чтобы скиллы появились в Personal skills, копируем SKILL.md туда и добавляем
# записи в manifest.json (creatorType: "user"). Префикс isb- избегает коллизий
# со встроенными (xlsx, docx и т.п.).

function New-SkillId {
  # Cowork требует skillId в формате 'skill_<26 chars base32>' для creatorType: "user".
  # Если skillId произвольный (например 'isb-contract-review') — Cowork сохраняет запись
  # в manifest, но НЕ показывает её в Settings → Skills → Personal skills.
  # Генерируем стабильный ID на основе имени скилла, чтобы повторные запуски
  # не плодили дубли.
  param([string]$Name)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("isb-cowork:$Name"))
  $sha.Dispose()
  $chars = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt 13; $i++) {
    $b = $hash[$i]
    [void]$sb.Append($chars[$b -band 0x1F])
    [void]$sb.Append($chars[($b -shr 5) -band 0x1F])
  }
  return "skill_$($sb.ToString().Substring(0, 26))"
}

function Read-SkillFrontmatter {
  param([string]$SkillMdPath)
  $result = @{ name = ""; description = "" }
  if (-not (Test-Path $SkillMdPath)) { return $result }
  $content = Get-Content $SkillMdPath -Raw -Encoding UTF8
  if ($content -match "(?ms)\A---\s*\r?\n(.*?)\r?\n---") {
    $fm = $matches[1]
    foreach ($line in $fm -split "`n") {
      if ($line -match '^\s*name:\s*"?(.+?)"?\s*$')         { $result.name = $matches[1].Trim() }
      if ($line -match '^\s*description:\s*"?(.+?)"?\s*$')  { $result.description = $matches[1].Trim() }
    }
  }
  return $result
}

if (Test-Path $CoworkSkillsPluginRoot) {
  $workspaceDirs = @(Get-ChildItem $CoworkSkillsPluginRoot -Directory -ErrorAction SilentlyContinue)
  $coworkPluginInstances = @()
  foreach ($ws in $workspaceDirs) {
    $pluginDirs = @(Get-ChildItem $ws.FullName -Directory -ErrorAction SilentlyContinue)
    foreach ($pl in $pluginDirs) {
      if (Test-Path (Join-Path $pl.FullName "manifest.json")) {
        $coworkPluginInstances += $pl.FullName
      }
    }
  }

  if ($coworkPluginInstances.Count -eq 0) {
    Write-Warn2 "Cowork plugin-instance не найден (папка $CoworkSkillsPluginRoot пуста). Запустите Cowork хотя бы один раз и перезапустите установщик чтобы скиллы появились в UI."
  } else {
    foreach ($coworkPluginDir in $coworkPluginInstances) {
      Write-Info "Регистрирую в Cowork UI: $coworkPluginDir"
      $coworkManifestPath = Join-Path $coworkPluginDir "manifest.json"
      $coworkSkillsDir    = Join-Path $coworkPluginDir "skills"
      New-Item -ItemType Directory -Force -Path $coworkSkillsDir | Out-Null

      try {
        $coworkManifest = Get-Content $coworkManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
      } catch {
        Write-Warn2 "  не смог прочитать manifest.json — пропускаю этот инстанс"
        continue
      }

      # Нормализуем skills в массив
      $existingSkills = @()
      if ($coworkManifest.skills) { $existingSkills = @($coworkManifest.skills) }

      foreach ($skillName in $skillsToInstall) {
        $srcSkillDir = Join-Path $PluginSkillsDir $skillName
        if (-not (Test-Path $srcSkillDir)) { continue }

        # ID скилла: формат 'skill_<26-char-base32>' (как Cowork требует для Personal skills)
        $isbSkillId  = New-SkillId -Name $skillName
        # Имя папки: с префиксом 'isb-' чтобы избежать коллизий со встроенными (xlsx, docx, ...)
        $cwSkillFolderName = "$IsbSkillPrefix$skillName"
        $cwSkillDir  = Join-Path $coworkSkillsDir $cwSkillFolderName

        # Копируем содержимое скилла
        if (Test-Path $cwSkillDir) { Remove-Item -Recurse -Force $cwSkillDir }
        Copy-Item -Recurse -Force $srcSkillDir $cwSkillDir

        # Извлекаем имя и описание из SKILL.md
        $fm = Read-SkillFrontmatter (Join-Path $cwSkillDir "SKILL.md")
        $skillDisplayName = if ($fm.name) { $fm.name } else { $skillName }
        $skillDescription = if ($fm.description) { $fm.description } else { "" }

        $entry = [PSCustomObject]@{
          skillId     = $isbSkillId
          name        = $skillDisplayName
          description = $skillDescription
          creatorType = "user"
          updatedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
          enabled     = $true
        }

        # Заменяем по skillId, или по старому формату (isb-<name>) для миграции с предыдущей версии
        $idx = -1
        for ($i = 0; $i -lt $existingSkills.Count; $i++) {
          if ($existingSkills[$i].skillId -eq $isbSkillId -or
              $existingSkills[$i].skillId -eq "$IsbSkillPrefix$skillName") {
            $idx = $i; break
          }
        }
        if ($idx -ge 0) {
          $existingSkills[$idx] = $entry
        } else {
          $existingSkills += $entry
        }
      }

      # Сохраняем обновлённый manifest
      $coworkManifest.skills = $existingSkills
      if (Get-Member -InputObject $coworkManifest -Name "lastUpdated" -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        $coworkManifest.lastUpdated = [int64](((Get-Date).ToUniversalTime() - (Get-Date "1970-01-01")).TotalMilliseconds)
      } else {
        $coworkManifest | Add-Member -NotePropertyName "lastUpdated" -NotePropertyValue ([int64](((Get-Date).ToUniversalTime() - (Get-Date "1970-01-01")).TotalMilliseconds))
      }
      Write-Utf8NoBom -Path $coworkManifestPath -Content ($coworkManifest | ConvertTo-Json -Depth 10)
      Write-Done "  записи добавлены в Cowork manifest"
    }
  }
} else {
  Write-Warn2 "Cowork app data не найдена ($CoworkSkillsPluginRoot). Запустите Cowork хотя бы один раз."
}

# --- 8. Register auto-update hook ---

if (-not $NoAutoUpdate -and -not $Silent) {
  Write-Info "Настраиваю автообновление при запуске Cowork"

  $rolesArg = $Roles -join ","
  $devFlag  = if ($IncludeDev) { " -IncludeDev" } else { "" }
  $thisScript = $MyInvocation.MyCommand.Path
  $updateCmd  = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$thisScript`" -Roles $rolesArg$devFlag -Silent -NoAutoUpdate"

  $settings = $null
  if (Test-Path $SettingsPath) {
    try {
      $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    } catch {
      Write-Warn2 "settings.json повреждён — пересоздаю"
      $settings = $null
    }
  }
  if ($null -eq $settings) {
    $settings = [PSCustomObject]@{}
  }

  $sessionStartArray = @(
    [PSCustomObject]@{
      matcher = "startup"
      hooks   = @(
        [PSCustomObject]@{ type = "command"; command = $updateCmd }
      )
    }
  )

  if (-not (Get-Member -InputObject $settings -Name 'hooks' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
    $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
  }
  if (-not (Get-Member -InputObject $settings.hooks -Name 'SessionStart' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
    $settings.hooks | Add-Member -NotePropertyName 'SessionStart' -NotePropertyValue $sessionStartArray
  } else {
    $settings.hooks.SessionStart = $sessionStartArray
  }

  $settingsDir = Split-Path $SettingsPath -Parent
  New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
  Write-Utf8NoBom -Path $SettingsPath -Content ($settings | ConvertTo-Json -Depth 10)
  Write-Done "Хук SessionStart зарегистрирован в $SettingsPath"
}

# --- 9. Summary ---

if (-not $Silent) {
  Write-Host ""
  Write-Host "================ Итог ================" -ForegroundColor Cyan
  Write-Host "Установлено / обновлено: $($succeeded.Count) скиллов" -ForegroundColor Green
  if ($failed.Count -gt 0) {
    Write-Host "Ошибок: $($failed.Count)" -ForegroundColor Yellow
    foreach ($f in $failed) {
      Write-Host "  - $($f.Name): $($f.Error)" -ForegroundColor Yellow
    }
  }
  Write-Host ""
  Write-Host "Скиллы лежат в плагине:" -ForegroundColor Cyan
  Write-Host "  $PluginDir"
  Write-Host ""
  Write-Host "Перезапустите Claude Cowork — скиллы появятся в Settings → Skills → Personal skills (с префиксом, но имя в чате остаётся как есть)." -ForegroundColor Green
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
