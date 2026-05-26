#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\InstallHelpers.ps1")

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]$Actual,
    [Parameter(Mandatory = $true)]$Expected,
    [string]$Message = "Values are not equal"
  )

  if ($Actual -ne $Expected) {
    throw "$Message. Expected: '$Expected'. Actual: '$Actual'."
  }
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [string]$Message = "Condition is false"
  )

  if (-not $Condition) { throw $Message }
}

function Assert-Throws {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
    [string]$Message = "Expected command to throw"
  )

  $thrown = $false
  try {
    & $ScriptBlock
  } catch {
    $thrown = $true
  }

  if (-not $thrown) { throw $Message }
}

function New-TestSkill {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$WithoutSkillMd
  )

  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  if (-not $WithoutSkillMd) {
    @'
---
name: demo-skill
description: Demo skill for installer tests.
---

# Demo Skill
'@ | Set-Content -LiteralPath (Join-Path $Path "SKILL.md") -Encoding UTF8
  }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "isb-install-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $defaultLinux = Get-ClaudeGlobalSkillsDir -ConfigDir "" -HomeDir "/home/alice"
  Assert-Equal -Actual $defaultLinux -Expected ([System.IO.Path]::GetFullPath("/home/alice/.claude/skills")) -Message "Linux/macOS default path should use ~/.claude/skills"

  $windowsHome = Join-Path $tempRoot "Users\Alice"
  $defaultWindows = Get-ClaudeGlobalSkillsDir -ConfigDir "" -HomeDir $windowsHome
  Assert-Equal -Actual $defaultWindows -Expected ([System.IO.Path]::GetFullPath((Join-Path $windowsHome ".claude\skills"))) -Message "Windows-like default path should use user .claude skills"

  $customConfig = Join-Path $tempRoot "custom-claude-config"
  $overridePath = Get-ClaudeGlobalSkillsDir -ConfigDir $customConfig -HomeDir $windowsHome
  Assert-Equal -Actual $overridePath -Expected ([System.IO.Path]::GetFullPath((Join-Path $customConfig "skills"))) -Message "CLAUDE_CONFIG_DIR should override ~/.claude"

  Assert-True -Condition (Test-SafeSkillName -Name "safe.skill-01_ok") -Message "Safe skill name was rejected"
  Assert-True -Condition (-not (Test-SafeSkillName -Name "..\bad")) -Message "Unsafe path-like skill name was accepted"
  Assert-Equal -Actual (ConvertTo-SafeCacheName -Value "C:\Temp\skill-repo") -Expected "C_Temp_skill-repo" -Message "Cache names should be safe on Windows"

  $badSkill = Join-Path $tempRoot "bad-skill"
  New-TestSkill -Path $badSkill -WithoutSkillMd
  Assert-Throws -ScriptBlock { Test-SkillSourceDirectory -SourceDir $badSkill | Out-Null } -Message "Skill without SKILL.md should fail validation"

  $skillsDir = Join-Path $tempRoot "global-skills"
  $sourceSkill = Join-Path $tempRoot "source-skill"
  New-TestSkill -Path $sourceSkill
  New-Item -ItemType Directory -Force -Path (Join-Path $sourceSkill "scripts") | Out-Null
  "script content" | Set-Content -LiteralPath (Join-Path $sourceSkill "scripts\helper.txt") -Encoding UTF8
  New-Item -ItemType Directory -Force -Path (Join-Path $sourceSkill "__pycache__") | Out-Null
  "junk" | Set-Content -LiteralPath (Join-Path $sourceSkill "__pycache__\junk.pyc") -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $skillsDir "other-skill") | Out-Null
  "keep me" | Set-Content -LiteralPath (Join-Path $skillsDir "other-skill\SKILL.md") -Encoding UTF8

  $firstResult = Install-SkillDirectory -SkillName "demo-skill" -SourceDir $sourceSkill -SkillsDir $skillsDir
  Assert-Equal -Actual $firstResult -Expected "installed" -Message "First install should be reported as installed"
  Assert-True -Condition (Test-Path -LiteralPath (Join-Path $skillsDir "demo-skill\scripts\helper.txt")) -Message "Skill resources should be copied"
  Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $skillsDir "demo-skill\__pycache__\junk.pyc"))) -Message "Ignored junk files should not be copied"
  Assert-True -Condition (Test-Path -LiteralPath (Join-Path $skillsDir "other-skill\SKILL.md")) -Message "Installer must not delete unrelated global skills"

  $secondResult = Install-SkillDirectory -SkillName "demo-skill" -SourceDir $sourceSkill -SkillsDir $skillsDir
  Assert-Equal -Actual $secondResult -Expected "updated" -Message "Second install should be reported as updated"

  Write-Host "All install helper tests passed."
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
