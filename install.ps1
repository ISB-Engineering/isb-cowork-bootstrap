#Requires -Version 5.1
<#
.SYNOPSIS
  Устанавливает скиллы Claude Cowork для сотрудника ИСБ по ролям.

.DESCRIPTION
  Скиллы кладутся напрямую в %USERPROFILE%\.claude\skills\<имя>\.
  Это работает: скиллы активируются по триггерам и через /slash в чате
  любой сессии Cowork и Claude Code.

  В Settings → Skills → Personal skills в Cowork UI они НЕ показываются —
  это известный баг Anthropic (issue anthropics/claude-code#50669, #31597,
  #52873, #26998): Cowork не сканирует ~/.claude/skills/ при запуске,
  держит отдельный внутренний реестр. Ждём фикс Anthropic.

  Этот скрипт также чистит за собой следы предыдущей попытки v0.5–v0.6
  (плагин ~/.claude/plugins/local/isb-cowork/ и записи в Cowork manifest).

.PARAMETER Roles
  Список ролей: owner, sales, service, finance, hr, supply, install, design, planning.

.PARAMETER IncludeDev
  Дополнительно поставить bundle 'dev' (методические + Vercel + Supabase).

.PARAMETER NoAutoUpdate
  Не регистрировать SessionStart хук.

.PARAMETER Silent
  Минимум вывода.
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
  [string]$SkillsDir    = (Join-Path $env:USERPROFILE ".claude\skills"),
  [string]$CacheDir     = (Join-Path $env:TEMP "isb-cowork-cache"),
  [string]$SettingsPath = (Join-Path $env:USERPROFILE ".claude\settings.json"),

  # Пути для очистки артефактов от v0.5/v0.6 (plugin format)
  [string]$LegacyPluginDir = (Join-Path $env:USERPROFILE ".claude\plugins\local\isb-cowork"),
  [string]$LegacyLocalMarketplace = (Join-Path $env:USERPROFILE ".claude\plugins\local\.claude-marketplace\marketplace.json"),
  [string]$CoworkSkillsPluginRoot = (Join-Path $env:APPDATA "Claude\local-agent-mode-sessions\skills-plugin")
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

if ($Roles.Count -eq 1 -and $Roles[0] -match ',') {
  $Roles = $Roles[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

Write-Info "Старт. Роли: $($Roles -join ', ')$(if ($IncludeDev) { ' + dev' })"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "Git не найден. Установите Git (https://git-scm.com/download/win) и повторите."
}

New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
New-Item -ItemType Directory -Force -Path $CacheDir  | Out-Null

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

# --- 4. CLEANUP: убрать артефакты v0.5/v0.6 (plugin format) ---

# 4a. Удалить локальный плагин ~/.claude/plugins/local/isb-cowork/
if (Test-Path $LegacyPluginDir) {
  Write-Info "Очистка: удаляю старый локальный плагин $LegacyPluginDir"
  Remove-Item -Recurse -Force $LegacyPluginDir
}

# 4b. Убрать запись isb-cowork из user-local marketplace
if (Test-Path $LegacyLocalMarketplace) {
  try {
    $lm = Get-Content $LegacyLocalMarketplace -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($lm.plugins) {
      $kept = @($lm.plugins | Where-Object { $_.name -ne "isb-cowork" })
      if ($kept.Count -lt @($lm.plugins).Count) {
        $lm.plugins = $kept
        Write-Utf8NoBom -Path $LegacyLocalMarketplace -Content ($lm | ConvertTo-Json -Depth 10)
        Write-Info "Очистка: запись isb-cowork удалена из $LegacyLocalMarketplace"
      }
    }
  } catch {
    Write-Warn2 "Очистка marketplace.json пропущена: $($_.Exception.Message)"
  }
}

# 4c. Убрать наши записи и папки из Cowork internal manifest
if (Test-Path $CoworkSkillsPluginRoot) {
  $manifestSkillNames = @($skillsToInstall)
  $workspaceDirs = @(Get-ChildItem $CoworkSkillsPluginRoot -Directory -ErrorAction SilentlyContinue)
  foreach ($ws in $workspaceDirs) {
    $pluginDirs = @(Get-ChildItem $ws.FullName -Directory -ErrorAction SilentlyContinue)
    foreach ($pl in $pluginDirs) {
      $cwManifest = Join-Path $pl.FullName "manifest.json"
      if (-not (Test-Path $cwManifest)) { continue }

      try {
        $cw = Get-Content $cwManifest -Raw -Encoding UTF8 | ConvertFrom-Json
      } catch { continue }

      $modified = $false
      if ($cw.skills) {
        # Удаляем наши записи (creatorType=user и имя соответствует нашему скиллу)
        $kept = @()
        foreach ($s in @($cw.skills)) {
          $isOurs = ($s.creatorType -eq "user") -and ($manifestSkillNames -contains $s.name)
          if ($isOurs) { $modified = $true } else { $kept += $s }
        }
        if ($modified) {
          $cw.skills = $kept
          Write-Utf8NoBom -Path $cwManifest -Content ($cw | ConvertTo-Json -Depth 10)
          Write-Info "Очистка: удалены наши записи из Cowork manifest $cwManifest"
        }
      }

      # Удаляем папки skills/isb-*/
      $cwSkillsDir = Join-Path $pl.FullName "skills"
      if (Test-Path $cwSkillsDir) {
        $isbDirs = Get-ChildItem $cwSkillsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "isb-*" }
        foreach ($d in $isbDirs) {
          Remove-Item -Recurse -Force $d.FullName
        }
        if ($isbDirs.Count -gt 0) { Write-Info "Очистка: удалено $($isbDirs.Count) папок isb-* из Cowork skills" }
      }
    }
  }
}

# --- 5. Install each skill ---

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
  $skillDir = Join-Path $SkillsDir $skillName

  try {
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

    $succeeded += $skillName
    Write-Done "OK: $skillName"
  } catch {
    $failed += [pscustomobject]@{ Name = $skillName; Error = $_.Exception.Message }
    Write-Warn2 "FAIL: $skillName — $($_.Exception.Message)"
  }
}

# --- 6. Register auto-update hook ---

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

# --- 7. Summary ---

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
  Write-Host "Скиллы лежат в:" -ForegroundColor Cyan
  Write-Host "  $SkillsDir"
  Write-Host ""
  Write-Host "Запустите Claude Cowork — скиллы активируются в чате по триггерам." -ForegroundColor Green
  Write-Host "В Settings → Skills они пока не показываются (известный баг Anthropic, ждём фикс)." -ForegroundColor Yellow
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
