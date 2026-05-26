#Requires -Version 5.1
<#
.SYNOPSIS
  Минимальный установщик скиллов ИСБ. Только копирование файлов в
  ~/.claude/skills/<имя>/. Никаких побочных эффектов.

.DESCRIPTION
  Версия v0.8.0 — возврат к простому подходу v0.4.0 после неудачных попыток
  v0.5-v0.7 интегрироваться с Cowork UI.

  - Ставит скиллы в %USERPROFILE%\.claude\skills\<имя>\
  - НЕ регистрирует SessionStart hook (никаких автозапусков)
  - НЕ трогает Cowork internal manifest
  - НЕ создаёт локальные плагины

  Скиллы активируются по триггерам в тексте (см. description в SKILL.md
  каждого скилла).

.PARAMETER Roles
  Список ролей: owner, sales, service, finance, hr, supply, install, design, planning.

.PARAMETER IncludeDev
  Дополнительно поставить bundle 'dev'.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string[]]$Roles,

  [switch]$IncludeDev,
  [switch]$Silent,

  [string]$ManifestPath = "",
  [string]$SkillsDir    = (Join-Path $env:USERPROFILE ".claude\skills"),
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

# --- 2. Убрать SessionStart hook если был установлен предыдущими версиями ---

if (Test-Path $SettingsPath) {
  try {
    $settings = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $modified = $false
    if ($settings.hooks -and (Get-Member -InputObject $settings.hooks -Name 'SessionStart' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
      # Удаляем только наши SessionStart-хуки (содержащие isb-cowork в command)
      $keptStarts = @()
      foreach ($block in @($settings.hooks.SessionStart)) {
        $isOurs = $false
        if ($block.hooks) {
          foreach ($h in @($block.hooks)) {
            if ($h.command -and $h.command -match 'isb-cowork|isb-install') { $isOurs = $true; break }
          }
        }
        if (-not $isOurs) { $keptStarts += $block }
      }
      if ($keptStarts.Count -ne @($settings.hooks.SessionStart).Count) {
        $modified = $true
        if ($keptStarts.Count -eq 0) {
          $settings.hooks.PSObject.Properties.Remove('SessionStart')
        } else {
          $settings.hooks.SessionStart = $keptStarts
        }
        Write-Info "Удалён SessionStart hook предыдущих версий"
      }
    }
    if ($modified) {
      Write-Utf8NoBom -Path $SettingsPath -Content ($settings | ConvertTo-Json -Depth 10)
    }
  } catch {
    Write-Warn2 "Не удалось почистить settings.json: $($_.Exception.Message)"
  }
}

# --- 3. Load manifest ---

if ($ManifestPath -and (Test-Path $ManifestPath)) {
  $manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
  $bootstrapRepoDir = Join-Path $CacheDir "ISB-Engineering_isb-cowork-bootstrap"
  Write-Info "Получаю manifest.json"
  try {
    if (Test-Path (Join-Path $bootstrapRepoDir ".git")) {
      Invoke-Git @("-C", $bootstrapRepoDir, "fetch", "--depth", "1", "--quiet", "origin", "main")
      Invoke-Git @("-C", $bootstrapRepoDir, "reset", "--hard", "--quiet", "FETCH_HEAD")
    } else {
      Invoke-Git @("clone", "--depth", "1", "--quiet", "https://github.com/ISB-Engineering/isb-cowork-bootstrap.git", $bootstrapRepoDir)
    }
  } catch {
    throw "Не удалось получить manifest.json: $($_.Exception.Message)"
  }
  $localManifest = Join-Path $bootstrapRepoDir "manifest.json"
  $manifest = Get-Content $localManifest -Raw -Encoding UTF8 | ConvertFrom-Json
}

# --- 4. Resolve bundles -> skills ---

function Resolve-Bundle($bundleName, $visited) {
  if ($visited -contains $bundleName) { return @() }
  $visited += $bundleName
  if (-not $manifest.bundles.$bundleName) {
    throw "Бандл '$bundleName' не найден. Доступные: $($manifest.bundles.PSObject.Properties.Name -join ', ')"
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

# --- 5. Install each skill ---

$succeeded = @()
$failed    = @()

foreach ($skillName in $skillsToInstall) {
  $spec = $manifest.skills.$skillName
  if (-not $spec) { continue }

  $repoUrl  = $spec.url
  $subPath  = $spec.path
  $ref      = if ($spec.ref) { $spec.ref } else { "main" }
  $repoSafe = ($repoUrl -replace "https://github.com/", "" -replace "\.git$", "" -replace "/", "_")
  $repoDir  = Join-Path $CacheDir $repoSafe
  $skillDir = Join-Path $SkillsDir $skillName

  try {
    if (-not (Test-Path (Join-Path $repoDir ".git"))) {
      Invoke-Git @("clone", "--depth", "1", "--quiet", "--branch", $ref, $repoUrl, $repoDir)
    } else {
      Invoke-Git @("-C", $repoDir, "fetch", "--depth", "1", "--quiet", "origin", $ref)
      Invoke-Git @("-C", $repoDir, "reset", "--hard", "--quiet", "FETCH_HEAD")
    }

    $srcDir = Join-Path $repoDir $subPath
    if (-not (Test-Path $srcDir)) { throw "Путь '$subPath' не найден в $repoUrl" }

    if (Test-Path $skillDir) { Remove-Item -Recurse -Force $skillDir }
    Copy-Item -Recurse -Force $srcDir $skillDir

    $succeeded += $skillName
    Write-Done "OK: $skillName"
  } catch {
    $failed += [pscustomobject]@{ Name = $skillName; Error = $_.Exception.Message }
    Write-Warn2 "FAIL: $skillName — $($_.Exception.Message)"
  }
}

# --- 6. Summary ---

if (-not $Silent) {
  Write-Host ""
  Write-Host "================ Итог ================" -ForegroundColor Cyan
  Write-Host "Установлено: $($succeeded.Count) скиллов" -ForegroundColor Green
  Write-Host ""
  Write-Host "Папка: $SkillsDir" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "ВАЖНО: полностью закройте Cowork (через диспетчер задач) и откройте заново." -ForegroundColor Yellow
  Write-Host "Скиллы активируются в чате по триггерам, например:" -ForegroundColor Cyan
  Write-Host '  "помоги проверить договор поставки на риски" → contract-review' -ForegroundColor Gray
  Write-Host '  "что это за поправка в законе РК" → npa-monitor' -ForegroundColor Gray
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
