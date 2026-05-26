#Requires -Version 5.1

function ConvertTo-InstallAbsolutePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$HomeDir = $HOME
  )

  $expanded = [Environment]::ExpandEnvironmentVariables($Path)
  if ($expanded -eq "~") {
    $expanded = $HomeDir
  } elseif ($expanded.StartsWith("~/") -or $expanded.StartsWith("~\")) {
    $expanded = Join-Path $HomeDir $expanded.Substring(2)
  }

  return [System.IO.Path]::GetFullPath($expanded)
}

function Get-ClaudeConfigDir {
  param(
    [string]$ConfigDir = $env:CLAUDE_CONFIG_DIR,
    [string]$HomeDir = $HOME
  )

  if (-not [string]::IsNullOrWhiteSpace($ConfigDir)) {
    return ConvertTo-InstallAbsolutePath -Path $ConfigDir -HomeDir $HomeDir
  }

  return ConvertTo-InstallAbsolutePath -Path (Join-Path $HomeDir ".claude") -HomeDir $HomeDir
}

function Get-ClaudeGlobalSkillsDir {
  param(
    [string]$ConfigDir = $env:CLAUDE_CONFIG_DIR,
    [string]$HomeDir = $HOME
  )

  return Join-Path (Get-ClaudeConfigDir -ConfigDir $ConfigDir -HomeDir $HomeDir) "skills"
}

function Get-ClaudeSettingsPath {
  param(
    [string]$ConfigDir = $env:CLAUDE_CONFIG_DIR,
    [string]$HomeDir = $HOME
  )

  return Join-Path (Get-ClaudeConfigDir -ConfigDir $ConfigDir -HomeDir $HomeDir) "settings.json"
}

function Test-SafeSkillName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  if ([System.IO.Path]::IsPathRooted($Name)) { return $false }
  if ($Name.Contains("/") -or $Name.Contains("\")) { return $false }
  if ($Name -eq "." -or $Name -eq ".." -or $Name.Contains("..")) { return $false }
  return ($Name -match '^[A-Za-z0-9._-]+$')
}

function Assert-SafeSkillName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if (-not (Test-SafeSkillName -Name $Name)) {
    throw "Unsafe skill name '$Name'. Allowed: letters, digits, dot, dash, underscore."
  }
}

function ConvertTo-SafeCacheName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $safe = $Value -replace '\.git$', ''
  $safe = $safe -replace '^[A-Za-z][A-Za-z0-9+.-]*://', ''
  $safe = $safe -replace '[^A-Za-z0-9._-]+', '_'
  $safe = $safe.Trim('._-')

  if ([string]::IsNullOrWhiteSpace($safe)) {
    return [guid]::NewGuid().ToString("N")
  }
  return $safe
}

function Test-IgnoredSkillPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RelativePath
  )

  $parts = $RelativePath -split '[\\/]+' | Where-Object { $_ }
  foreach ($part in $parts) {
    if ($part -in @(".git", "__pycache__", "node_modules", ".venv")) { return $true }
  }

  $leaf = Split-Path $RelativePath -Leaf
  if ($leaf -eq ".DS_Store") { return $true }
  if ($leaf -like "*.pyc") { return $true }
  return $false
}

function Test-SkillSourceDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir
  )

  if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    throw "Source skill directory not found: $SourceDir"
  }

  $skillMd = Join-Path $SourceDir "SKILL.md"
  if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) {
    throw "SKILL.md not found in $SourceDir"
  }

  $content = Get-Content -LiteralPath $skillMd -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($content)) {
    throw "SKILL.md is empty in $SourceDir"
  }

  if ($content -notmatch '(?s)^---\r?\n(.+?)\r?\n---') {
    throw "SKILL.md must start with YAML frontmatter in $SourceDir"
  }

  $frontmatter = $Matches[1]
  if ($frontmatter -notmatch '(?m)^description\s*:') {
    throw "SKILL.md frontmatter must contain description in $SourceDir"
  }

  return $true
}

function Get-SkillFrontmatterValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [Parameter(Mandatory = $true)]
    [string]$FieldName
  )

  $skillMd = Join-Path $SourceDir "SKILL.md"
  $content = Get-Content -LiteralPath $skillMd -Raw -Encoding UTF8
  if ($content -notmatch '(?s)^---\r?\n(.+?)\r?\n---') {
    return ""
  }

  $frontmatter = $Matches[1]
  $pattern = "(?m)^$([regex]::Escape($FieldName))\s*:\s*(.+?)\s*$"
  if ($frontmatter -notmatch $pattern) {
    return ""
  }

  $value = $Matches[1].Trim()
  if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
    $value = $value.Substring(1, $value.Length - 2)
  }
  return $value
}

function Copy-SkillTree {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [Parameter(Mandatory = $true)]
    [string]$DestinationDir
  )

  $sourceRoot = (Get-Item -LiteralPath $SourceDir).FullName
  New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null

  Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force | ForEach-Object {
    $relativePath = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
    if (Test-IgnoredSkillPath -RelativePath $relativePath) { return }

    $targetPath = Join-Path $DestinationDir $relativePath
    if ($_.PSIsContainer) {
      New-Item -ItemType Directory -Force -Path $targetPath | Out-Null
    } else {
      $targetParent = Split-Path $targetPath -Parent
      New-Item -ItemType Directory -Force -Path $targetParent | Out-Null
      Copy-Item -LiteralPath $_.FullName -Destination $targetPath -Force
    }
  }
}

function Write-IsbRoleCatalogSource {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CatalogDir,

    [Parameter(Mandatory = $true)]
    [string[]]$Roles,

    [Parameter(Mandatory = $true)]
    [string]$CatalogTemplatesDir
  )

  if (-not (Test-Path -LiteralPath $CatalogTemplatesDir -PathType Container)) {
    throw "Role catalog templates directory not found: $CatalogTemplatesDir"
  }

  New-Item -ItemType Directory -Force -Path $CatalogDir | Out-Null
  $referencesDir = Join-Path $CatalogDir "references"
  $rolesDir = Join-Path $referencesDir "roles"
  New-Item -ItemType Directory -Force -Path $rolesDir | Out-Null

  $skillMd = @'
---
name: isb-role-skills-catalog
description: Используй, когда сотрудник ИСБ спрашивает, какие AI-скиллы Claude доступны ему по роли, что умеет его набор, или просит показать справочник скиллов.
---

# Каталог AI-скиллов ИСБ

Когда сотрудник спрашивает, какие скиллы ему доступны, читай файлы в `references/roles/` и отвечай простым русским языком.

Если сотрудник спрашивает в общем, сначала открой `references/installed-roles.md`, затем нужные файлы ролей.

Не выдумывай возможности, которых нет в локальных файлах ролей.
'@
  Set-Content -LiteralPath (Join-Path $CatalogDir "SKILL.md") -Value $skillMd -Encoding UTF8

  $installedRoles = New-Object System.Collections.Generic.List[string]

  foreach ($role in ($Roles | Sort-Object -Unique)) {
    Assert-SafeSkillName -Name $role
    $sourceRoleFile = Join-Path $CatalogTemplatesDir "roles\$role.md"
    if (-not (Test-Path -LiteralPath $sourceRoleFile -PathType Leaf)) {
      throw "Role catalog file not found: $sourceRoleFile"
    }

    Copy-Item -LiteralPath $sourceRoleFile -Destination (Join-Path $rolesDir "$role.md") -Force
    $installedRoles.Add($role) | Out-Null
  }

  $summary = New-Object System.Collections.Generic.List[string]
  $summary.Add("# Установленные справочники ролей ИСБ") | Out-Null
  $summary.Add("") | Out-Null
  $summary.Add("Этот каталог создан установщиком isb-cowork-bootstrap для ролей, выбранных на этом компьютере.") | Out-Null
  $summary.Add("") | Out-Null
  $summary.Add("Выбранные роли: $($installedRoles -join ', ')") | Out-Null
  $summary.Add("") | Out-Null
  $summary.Add("Файлы ролей:") | Out-Null
  foreach ($role in $installedRoles) {
    $summary.Add("- ``references/roles/$role.md``") | Out-Null
  }
  Set-Content -LiteralPath (Join-Path $referencesDir "installed-roles.md") -Value ($summary -join [Environment]::NewLine) -Encoding UTF8
}

function Clear-InstallBlockingAttributes {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) { return }

  $items = @(Get-Item -LiteralPath $Path -Force)
  $items += @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
  foreach ($item in $items) {
    try {
      $item.Attributes = ($item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly))
      $item.Attributes = ($item.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden))
      $item.Attributes = ($item.Attributes -band (-bnot [System.IO.FileAttributes]::System))
    } catch {
      # Best effort. The actual replace step will report a clear failure if this matters.
    }
  }
}

function Move-InstallDirectoryWithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [int]$Attempts = 3
  )

  $lastError = $null
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      Move-Item -LiteralPath $Source -Destination $Destination -Force
      return
    } catch {
      $lastError = $_.Exception.Message
      Start-Sleep -Milliseconds (250 * $attempt)
    }
  }

  throw "Cannot replace '$Source': $lastError. Close Claude/Cowork and any Explorer window opened inside this folder, then rerun the installer."
}

function Install-SkillDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SkillName,

    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [Parameter(Mandatory = $true)]
    [string]$SkillsDir,

    [switch]$DryRun
  )

  Assert-SafeSkillName -Name $SkillName
  Test-SkillSourceDirectory -SourceDir $SourceDir | Out-Null

  $targetDir = Join-Path $SkillsDir $SkillName
  $exists = Test-Path -LiteralPath $targetDir -PathType Container

  if ($DryRun) {
    if ($exists) { return "would-update" }
    return "would-install"
  }

  New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
  $tempDir = Join-Path $SkillsDir ".$SkillName.installing.$([guid]::NewGuid().ToString('N'))"
  $backupDir = Join-Path $SkillsDir ".$SkillName.backup.$([guid]::NewGuid().ToString('N'))"

  try {
    Copy-SkillTree -SourceDir $SourceDir -DestinationDir $tempDir

    if ($exists) {
      Clear-InstallBlockingAttributes -Path $targetDir
      Move-InstallDirectoryWithRetry -Source $targetDir -Destination $backupDir
    }

    Move-InstallDirectoryWithRetry -Source $tempDir -Destination $targetDir

    if (Test-Path -LiteralPath $backupDir) {
      Clear-InstallBlockingAttributes -Path $backupDir
      Remove-Item -LiteralPath $backupDir -Recurse -Force
    }

    if ($exists) { return "updated" }
    return "installed"
  } catch {
    if ((-not (Test-Path -LiteralPath $targetDir)) -and (Test-Path -LiteralPath $backupDir)) {
      Move-Item -LiteralPath $backupDir -Destination $targetDir -Force
    }
    if (Test-Path -LiteralPath $tempDir) {
      Clear-InstallBlockingAttributes -Path $tempDir
      Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $backupDir) {
      Clear-InstallBlockingAttributes -Path $backupDir
      Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
  }
}
