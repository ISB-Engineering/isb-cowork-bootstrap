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
  [string]$SettingsPath = (Join-Path $env:USERPROFILE ".claude\settings.json")
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
$pluginManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $pluginManifestPath -Encoding UTF8

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

$mp | ConvertTo-Json -Depth 10 | Set-Content -Path $LocalMarketplaceFile -Encoding UTF8
Write-Info "Зарегистрирован в локальном marketplace: $LocalMarketplaceFile"

# --- 7. Register auto-update hook ---

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
  $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsPath -Encoding UTF8
  Write-Done "Хук SessionStart зарегистрирован в $SettingsPath"
}

# --- 8. Summary ---

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
  Write-Host "Перезапустите Claude Cowork — скиллы появятся в Settings → Skills → Personal skills." -ForegroundColor Green
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
