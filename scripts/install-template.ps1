<#
.SYNOPSIS
    install.ps1 -- Install the {{SKILL_NAME}} skill (cross-platform skill installer template).

.DESCRIPTION
    PowerShell sibling of install-template.sh. During skill generation,
    {{SKILL_NAME}} is replaced with the actual skill name and the result
    is shipped as install.ps1 inside every generated skill package alongside
    install.sh. Targets PowerShell 5.1 (built into Windows 10/11).

    Three-tier link fallback: SymbolicLink -> Junction -> Copy.
    See docs/windows-support.md in the skillwright repo for design rationale.

.PARAMETER Platform
    Explicit platform selection. One of: claude-code, copilot, cursor,
    windsurf, cline, codex, gemini, kiro, trae, goose, opencode, roo-code,
    antigravity, universal.

.PARAMETER Project
    Install at project level (current directory) rather than user-level.

.PARAMETER Path
    Custom install path (overrides detection).

.PARAMETER All
    Install to ALL detected tool paths at once.

.PARAMETER DryRun
    Show what would happen without making changes.

.EXAMPLE
    .\install.ps1                           # Auto-detect platform, user-level
    .\install.ps1 -Project                  # Auto-detect platform, project-level
    .\install.ps1 -Platform cursor          # Force Cursor, user-level
    .\install.ps1 -Path C:\my-skills\       # Custom destination
    .\install.ps1 -All                      # Install to every detected tool
    .\install.ps1 -DryRun                   # Preview without installing

.NOTES
    Exit codes:
      0 — Success
      1 — Validation failed (missing or malformed SKILL.md)
      2 — Platform not detected
      3 — Permission denied
#>
[CmdletBinding()]
param(
    [string] $Platform,
    [switch] $Project,
    [string] $Path,
    [switch] $All,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants — {{SKILL_NAME}} is substituted at generation time
# ---------------------------------------------------------------------------
$SkillName = '{{SKILL_NAME}}'
$Version   = '1.0.0'
$ScriptDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:UseColor = $Host.UI.RawUI -and -not [Console]::IsOutputRedirected
function Write-Info    { param([string]$Message) if ($script:UseColor) { Write-Host '[INFO]  ' -ForegroundColor Blue -NoNewline } else { Write-Host '[INFO]  ' -NoNewline }; Write-Host $Message }
function Write-Ok      { param([string]$Message) if ($script:UseColor) { Write-Host '[OK]    ' -ForegroundColor Green -NoNewline } else { Write-Host '[OK]    ' -NoNewline }; Write-Host $Message }
function Write-WarnMsg { param([string]$Message) if ($script:UseColor) { Write-Host '[WARN]  ' -ForegroundColor Yellow -NoNewline } else { Write-Host '[WARN]  ' -NoNewline }; Write-Host $Message }
function Write-Err     { param([string]$Message) if ($script:UseColor) { Write-Host '[ERROR] ' -ForegroundColor Red -NoNewline } else { Write-Host '[ERROR] ' -NoNewline }; Write-Host $Message }

# BOM-less UTF-8 writer (PS 5.1 quirk; see docs/windows-support.md §7a).
function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Content,
        [switch] $Append
    )
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if ($Append -and (Test-Path -LiteralPath $Path)) {
        $existing = [System.IO.File]::ReadAllText($Path, $utf8)
        [System.IO.File]::WriteAllText($Path, $existing + $Content, $utf8)
    } else {
        [System.IO.File]::WriteAllText($Path, $Content, $utf8)
    }
}

# ---------------------------------------------------------------------------
# SKILL.md validation (mirrors validate_skill_md in install-template.sh)
# ---------------------------------------------------------------------------
function Test-SkillMd {
    $skillMd = Join-Path $ScriptDir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd)) {
        Write-Err "SKILL.md not found in $ScriptDir"
        Write-Err 'Every skill package must contain a valid SKILL.md file.'
        exit 1
    }

    $lines = Get-Content -LiteralPath $skillMd -ErrorAction Stop
    if ($lines.Count -eq 0 -or $lines[0] -ne '---') {
        Write-Err 'SKILL.md must start with YAML frontmatter (---)'
        exit 1
    }

    $foundName = $false
    $foundDesc = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') { break }
        if ($lines[$i] -match '^name:\s*\S')        { $foundName = $true }
        if ($lines[$i] -match '^description:\s*\S') { $foundDesc = $true }
    }

    if (-not $foundName) { Write-Err 'SKILL.md frontmatter is missing required field: name'; exit 1 }
    if (-not $foundDesc) { Write-Err 'SKILL.md frontmatter is missing required field: description'; exit 1 }

    Write-Ok 'SKILL.md validated (name and description present)'
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
$SupportedPlatforms = @(
    'claude-code','copilot','cursor','windsurf','cline','codex','gemini',
    'kiro','trae','goose','opencode','roo-code','antigravity','universal'
)

function Resolve-Platform {
    if (-not [string]::IsNullOrEmpty($Platform)) {
        if ($SupportedPlatforms -contains $Platform) {
            Write-Info "Platform explicitly set to: $Platform"
            return $Platform
        }
        Write-Err "Unknown platform: $Platform"
        Write-Err ("Supported: {0}" -f ($SupportedPlatforms -join ', '))
        exit 2
    }

    # Auto-detect, most-specific first.
    $detected = $null
    if (Test-Path -LiteralPath "$HOME\.claude" -PathType Container) { $detected = 'claude-code' }
    elseif ((Test-Path -LiteralPath "$HOME\.cursor" -PathType Container) -or (Test-Path -LiteralPath '.cursor' -PathType Container)) { $detected = 'cursor' }
    elseif ((Test-Path -LiteralPath "$HOME\.codeium\windsurf" -PathType Container) -or (Test-Path -LiteralPath '.windsurf' -PathType Container)) { $detected = 'windsurf' }
    elseif ((Test-Path -LiteralPath "$HOME\.cline" -PathType Container) -or (Test-Path -LiteralPath '.clinerules' -PathType Container)) { $detected = 'cline' }
    elseif (Test-Path -LiteralPath "$HOME\.gemini" -PathType Container) { $detected = 'gemini' }
    elseif (Test-Path -LiteralPath '.kiro' -PathType Container) { $detected = 'kiro' }
    elseif (Test-Path -LiteralPath '.trae' -PathType Container) { $detected = 'trae' }
    elseif (Test-Path -LiteralPath '.roo'  -PathType Container) { $detected = 'roo-code' }
    elseif (Test-Path -LiteralPath "$HOME\.config\goose" -PathType Container) { $detected = 'goose' }
    elseif (Test-Path -LiteralPath "$HOME\.config\opencode" -PathType Container) { $detected = 'opencode' }
    elseif (Test-Path -LiteralPath "$HOME\.agents" -PathType Container) { $detected = 'universal' }
    elseif ((Test-Path -LiteralPath "$HOME\.copilot" -PathType Container) -or (Test-Path -LiteralPath '.github' -PathType Container)) { $detected = 'copilot' }

    if (-not $detected) {
        Write-Err 'Could not auto-detect any supported AI coding platform.'
        Write-Err 'Use -Platform <name> to specify one explicitly.'
        Write-Err ("Supported: {0}" -f ($SupportedPlatforms -join ', '))
        exit 2
    }

    Write-Info "Auto-detected platform: $detected"
    return $detected
}

function Get-AllDetectedPlatforms {
    $detected = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath "$HOME\.claude" -PathType Container) { $detected.Add('claude-code') | Out-Null }
    if ((Test-Path -LiteralPath "$HOME\.cursor" -PathType Container) -or (Test-Path -LiteralPath '.cursor' -PathType Container)) { $detected.Add('cursor') | Out-Null }
    if ((Test-Path -LiteralPath "$HOME\.codeium\windsurf" -PathType Container) -or (Test-Path -LiteralPath '.windsurf' -PathType Container)) { $detected.Add('windsurf') | Out-Null }
    if ((Test-Path -LiteralPath "$HOME\.cline" -PathType Container) -or (Test-Path -LiteralPath '.clinerules' -PathType Container)) { $detected.Add('cline') | Out-Null }
    if (Test-Path -LiteralPath "$HOME\.gemini" -PathType Container) { $detected.Add('gemini') | Out-Null }
    if (Test-Path -LiteralPath '.kiro' -PathType Container) { $detected.Add('kiro') | Out-Null }
    if (Test-Path -LiteralPath '.trae' -PathType Container) { $detected.Add('trae') | Out-Null }
    if (Test-Path -LiteralPath '.roo'  -PathType Container) { $detected.Add('roo-code') | Out-Null }
    if (Test-Path -LiteralPath "$HOME\.config\goose" -PathType Container) { $detected.Add('goose') | Out-Null }
    if (Test-Path -LiteralPath "$HOME\.config\opencode" -PathType Container) { $detected.Add('opencode') | Out-Null }
    if ((Test-Path -LiteralPath "$HOME\.copilot" -PathType Container) -or (Test-Path -LiteralPath '.github' -PathType Container)) { $detected.Add('copilot') | Out-Null }
    $detected.Add('universal') | Out-Null
    return $detected
}

# ---------------------------------------------------------------------------
# Install path resolution
# ---------------------------------------------------------------------------
function Resolve-InstallDir {
    param(
        [Parameter(Mandatory)] [string] $Plat,
        [bool] $ProjectLevel,
        [string] $CustomPath
    )

    if (-not [string]::IsNullOrEmpty($CustomPath)) {
        Write-Info "Using custom install path: $CustomPath"
        return $CustomPath
    }

    if ($ProjectLevel) {
        $base = switch ($Plat) {
            'claude-code' { '.claude\skills'   }
            'copilot'     { '.github\skills'   }
            'cursor'      { '.cursor\rules'    }
            'windsurf'    { '.windsurf\rules'  }
            'cline'       { '.clinerules'      }
            'codex'       { '.agents\skills'   }
            'gemini'      { '.gemini\skills'   }
            'kiro'        { '.kiro\skills'     }
            'trae'        { '.trae\rules'      }
            'goose'       { '.agents\skills'   }
            'opencode'    { '.agents\skills'   }
            'roo-code'    { '.roo\rules'       }
            'antigravity' { '.agents\skills'   }
            'universal'   { '.agents\skills'   }
            default       { '.agents\skills'   }
        }
        return (Join-Path (Get-Location).Path (Join-Path $base $SkillName))
    }

    $base = switch ($Plat) {
        'claude-code' { "$HOME\.claude\skills"           }
        'copilot'     { "$HOME\.copilot\skills"          }
        'cursor'      { "$HOME\.cursor\rules"            }
        'windsurf'    { "$HOME\.codeium\windsurf\skills" }
        'cline'       { "$HOME\.cline\rules"             }
        'codex'       { "$HOME\.agents\skills"           }
        'gemini'      { "$HOME\.gemini\skills"           }
        'kiro'        { "$HOME\.agents\skills"           }
        'trae'        { "$HOME\.agents\skills"           }
        'goose'       { "$HOME\.config\goose\skills"     }
        'opencode'    { "$HOME\.config\opencode\skills"  }
        'roo-code'    { "$HOME\.agents\skills"           }
        'antigravity' { "$HOME\.agents\skills"           }
        'universal'   { "$HOME\.agents\skills"           }
        default       { "$HOME\.agents\skills"           }
    }
    return (Join-Path $base $SkillName)
}

# ---------------------------------------------------------------------------
# Frontmatter helpers
# ---------------------------------------------------------------------------
function Read-FrontmatterField {
    param(
        [Parameter(Mandatory)] [string] $SkillMdPath,
        [Parameter(Mandatory)] [string] $Field
    )
    $lines = Get-Content -LiteralPath $SkillMdPath
    if ($lines.Count -eq 0 -or $lines[0] -ne '---') { return '' }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') { break }
        if ($lines[$i] -match "^${Field}:\s*(.*)$") {
            $val = $matches[1]
            if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $matches[1] }
            return $val
        }
    }
    return ''
}

function Get-SkillBody {
    param([Parameter(Mandatory)] [string] $SkillMdPath)
    $lines = Get-Content -LiteralPath $SkillMdPath
    $delim = 0
    $bodyStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') {
            $delim++
            if ($delim -eq 2) { $bodyStart = $i + 1; break }
        }
    }
    if ($bodyStart -lt 0 -or $bodyStart -ge $lines.Count) { return '' }
    return ($lines[$bodyStart..($lines.Count - 1)] -join "`n")
}

# ---------------------------------------------------------------------------
# Format adapters
# ---------------------------------------------------------------------------
function Invoke-CursorMdcAdapter {
    param([string]$TargetDir)
    $skillMd = Join-Path $ScriptDir 'SKILL.md'
    $desc    = Read-FrontmatterField -SkillMdPath $skillMd -Field 'description'
    $mdcFile = Join-Path $TargetDir "$SkillName.mdc"

    if ($DryRun) { Write-Info "Would generate Cursor .mdc: $mdcFile"; return }

    $body = Get-SkillBody -SkillMdPath $skillMd
    $content = @"
---
description: $desc
globs:
alwaysApply: true
---
$body
"@
    if (-not (Test-Path -LiteralPath $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
    Write-Utf8NoBom -Path $mdcFile -Content $content
    Write-Ok "Generated Cursor .mdc: $mdcFile"
}

function Invoke-WindsurfRuleAdapter {
    param([string]$TargetDir, [bool]$IsGlobal)
    $skillMd = Join-Path $ScriptDir 'SKILL.md'
    $body    = Get-SkillBody -SkillMdPath $skillMd

    if ($IsGlobal) {
        $globalFile = "$HOME\.codeium\windsurf\memories\global_rules.md"
        if ($DryRun) { Write-Info "Would append to Windsurf global_rules.md: $globalFile"; return }

        $globalDir = Split-Path -Parent $globalFile
        if (-not (Test-Path -LiteralPath $globalDir)) { New-Item -ItemType Directory -Path $globalDir -Force | Out-Null }

        $beginMarker = "<!-- BEGIN $SkillName -->"
        $endMarker   = "<!-- END $SkillName -->"

        if (Test-Path -LiteralPath $globalFile) {
            $existing = Get-Content -LiteralPath $globalFile
            $kept = New-Object System.Collections.Generic.List[string]
            $skip = $false
            foreach ($line in $existing) {
                if ($line -eq $beginMarker) { $skip = $true; continue }
                if ($line -eq $endMarker)   { $skip = $false; continue }
                if (-not $skip) { $kept.Add($line) | Out-Null }
            }
            Write-Utf8NoBom -Path $globalFile -Content (($kept -join "`n") + "`n")
        }

        $append = @"

$beginMarker
$body
$endMarker
"@
        Write-Utf8NoBom -Path $globalFile -Content $append -Append
        Write-Ok 'Appended to Windsurf global_rules.md'
    } else {
        $ruleFile = Join-Path $TargetDir "$SkillName.md"
        if ($DryRun) { Write-Info "Would generate Windsurf rule: $ruleFile"; return }
        if (-not (Test-Path -LiteralPath $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
        Write-Utf8NoBom -Path $ruleFile -Content $body
        Write-Ok "Generated Windsurf rule: $ruleFile"
    }
}

function Invoke-PlainRuleAdapter {
    param([string]$TargetDir, [string]$Filename)
    $skillMd  = Join-Path $ScriptDir 'SKILL.md'
    $plainFile = Join-Path $TargetDir $Filename

    if ($DryRun) { Write-Info "Would generate plain rule: $plainFile"; return }

    if (-not (Test-Path -LiteralPath $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
    Write-Utf8NoBom -Path $plainFile -Content (Get-SkillBody -SkillMdPath $skillMd)
    Write-Ok "Generated plain rule: $plainFile"
}

# ---------------------------------------------------------------------------
# Three-tier link (symlink -> junction -> copy)
# ---------------------------------------------------------------------------
function New-SkillLink {
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $LinkPath
    )
    if ($Target -eq $LinkPath) { return 'noop' }

    $parent = Split-Path -Parent $LinkPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) { Remove-Item -LiteralPath $LinkPath -Recurse -Force }

    try { New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null; return 'symlink' } catch { }
    if (Test-Path -LiteralPath $Target -PathType Container) {
        try { New-Item -ItemType Junction -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null; return 'junction' } catch { }
    }
    Write-WarnMsg "Could not create symlink or junction for $LinkPath. Falling back to file copy."
    Copy-Item -LiteralPath $Target -Destination $LinkPath -Recurse -Force
    return 'copy'
}

# ---------------------------------------------------------------------------
# Universal secondary install (~/.agents/skills/)
# ---------------------------------------------------------------------------
function Install-UniversalSecondary {
    param([string]$Plat, [string]$InstallDir)
    if ($Plat -in @('codex','antigravity','universal')) { return }
    $universal = "$HOME\.agents\skills\$SkillName"

    if ($DryRun) { Write-Info "Would create universal link: $universal -> $InstallDir"; return }

    $parent = Split-Path -Parent $universal
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path -LiteralPath $universal) { Remove-Item -LiteralPath $universal -Recurse -Force }

    try {
        New-Item -ItemType SymbolicLink -Path $universal -Target $InstallDir -ErrorAction Stop | Out-Null
        Write-Ok "Universal symlink: $universal -> $InstallDir"
        return
    } catch { }
    try {
        New-Item -ItemType Junction -Path $universal -Target $InstallDir -ErrorAction Stop | Out-Null
        Write-Ok "Universal junction: $universal -> $InstallDir"
        return
    } catch { }
    try {
        Copy-Item -LiteralPath $InstallDir -Destination $universal -Recurse -Force
        Write-Ok "Universal copy: $universal"
    } catch {
        Write-WarnMsg "Could not create universal path at $universal"
    }
}

# ---------------------------------------------------------------------------
# Copy skill payload to install dir (idempotent)
# ---------------------------------------------------------------------------
function Copy-SkillFiles {
    param([string]$InstallDir)

    if ($DryRun) {
        Write-Host ''
        Write-Host 'Dry-run mode -- no files will be copied.' -ForegroundColor White
        Write-Host ''
        Write-Info "Would create directory: $InstallDir"
        $count = 0
        foreach ($item in Get-ChildItem -LiteralPath $ScriptDir -Force) {
            if ($item.Name -in @('install.sh', 'install.ps1')) { continue }
            Write-Info "Would copy: $($item.Name)"
            $count++
        }
        Write-Host ''
        Write-Info "Total files: $count"
        return
    }

    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
    try {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    } catch {
        Write-Err "Cannot create directory: $InstallDir"
        Write-Err 'Check file permissions or run with appropriate privileges.'
        exit 3
    }

    $count = 0
    foreach ($item in Get-ChildItem -LiteralPath $ScriptDir -Force) {
        if ($item.Name -in @('install.sh', 'install.ps1')) { continue }
        try {
            Copy-Item -LiteralPath $item.FullName -Destination $InstallDir -Recurse -Force
            $count++
        } catch {
            Write-Err "Failed to copy $($item.Name) to $InstallDir"
            Write-Err 'Check file permissions.'
            exit 3
        }
    }
    Write-Ok "Copied $count file(s) to $InstallDir"
}

# ---------------------------------------------------------------------------
# Run adapters
# ---------------------------------------------------------------------------
function Invoke-Adapters {
    param([string]$Plat, [string]$InstallDir, [bool]$ProjectLevel)
    switch ($Plat) {
        'cursor' { Invoke-CursorMdcAdapter -TargetDir $InstallDir }
        'windsurf' {
            if ($ProjectLevel) {
                $rulesDir = Join-Path (Get-Location).Path '.windsurf\rules'
                Invoke-WindsurfRuleAdapter -TargetDir $rulesDir -IsGlobal $false
            } else {
                Invoke-WindsurfRuleAdapter -TargetDir '' -IsGlobal $true
            }
        }
        'cline'    { Invoke-PlainRuleAdapter -TargetDir $InstallDir -Filename "$SkillName.md" }
        'roo-code' { Invoke-PlainRuleAdapter -TargetDir $InstallDir -Filename "$SkillName.md" }
        'trae'     { Invoke-PlainRuleAdapter -TargetDir $InstallDir -Filename "$SkillName.md" }
    }
}

# ---------------------------------------------------------------------------
# Activation instructions
# ---------------------------------------------------------------------------
function Show-ActivationInstructions {
    param([string]$Plat, [string]$InstallDir, [bool]$ProjectLevel)
    if ($DryRun) { return }

    Write-Host ''
    Write-Host 'Installation complete!' -ForegroundColor Green
    Write-Host ''

    switch ($Plat) {
        'claude-code' {
            Write-Host 'To activate the skill in Claude Code:'
            Write-Host '  1. Start a new Claude Code session.'
            Write-Host '  2. The skill will be loaded automatically from:'
            Write-Host "     $InstallDir\SKILL.md"
            Write-Host "  3. Use trigger phrases defined in the skill's description."
        }
        'copilot' {
            Write-Host 'To activate the skill in GitHub Copilot:'
            Write-Host '  1. Open your project in VS Code or the GitHub CLI.'
            Write-Host '  2. The skill is available at:'
            Write-Host "     $InstallDir\SKILL.md"
            Write-Host '  3. Reference the skill in your Copilot instructions.'
        }
        'cursor' {
            Write-Host 'To activate the skill in Cursor:'
            Write-Host '  1. Open your project in Cursor.'
            Write-Host '  2. The rule is loaded automatically from:'
            Write-Host "     $InstallDir\$SkillName.mdc"
            Write-Host '  3. Use trigger phrases to invoke the skill.'
        }
        'windsurf' {
            Write-Host 'To activate the skill in Windsurf:'
            if ($ProjectLevel) {
                Write-Host '  1. Open your project in Windsurf.'
                Write-Host '  2. The rule is loaded from .windsurf\rules\'
            } else {
                Write-Host '  1. Open Windsurf.'
                Write-Host '  2. The skill was added to global_rules.md.'
            }
            Write-Host '  3. Use trigger phrases to invoke the skill.'
        }
        'cline' {
            Write-Host 'To activate the skill in Cline:'
            Write-Host '  1. Open your project in VS Code with Cline.'
            Write-Host '  2. The rule is loaded from:'
            Write-Host "     $InstallDir\$SkillName.md"
            Write-Host '  3. Cline will pick up the rule automatically.'
        }
        'codex' {
            Write-Host 'To activate the skill in OpenAI Codex CLI:'
            Write-Host '  1. Start a new Codex CLI session.'
            Write-Host '  2. The skill is available at:'
            Write-Host "     $InstallDir\SKILL.md"
            Write-Host '  3. Codex reads from ~\.agents\skills\ automatically.'
        }
        'gemini' {
            Write-Host 'To activate the skill in Gemini CLI:'
            Write-Host '  1. Start a new Gemini CLI session.'
            Write-Host '  2. The skill is available at:'
            Write-Host "     $InstallDir\SKILL.md"
            Write-Host '  3. The skill will be loaded automatically.'
        }
        'kiro' {
            Write-Host 'To activate the skill in Kiro:'
            Write-Host '  1. Open your project in Kiro.'
            Write-Host '  2. The skill is available at:'
            Write-Host "     $InstallDir\SKILL.md"
            Write-Host '  3. Kiro reads from .kiro\skills\ automatically.'
        }
        'trae' {
            Write-Host 'To activate the skill in Trae:'
            Write-Host '  1. Open your project in Trae.'
            Write-Host '  2. The rule is loaded from:'
            Write-Host "     $InstallDir\$SkillName.md"
            Write-Host '  3. Use trigger phrases to invoke the skill.'
        }
        'goose' {
            Write-Host 'To activate the skill in Goose:'
            Write-Host '  1. Start a new Goose session.'
            Write-Host '  2. The skill is available at:'
            Write-Host "     $InstallDir\SKILL.md"
            Write-Host '  3. Goose reads from ~\.config\goose\skills\ automatically.'
        }
        'opencode' {
            Write-Host 'To activate the skill in OpenCode:'
            Write-Host '  1. Start a new OpenCode session.'
            Write-Host '  2. The skill is available at:'
            Write-Host "     $InstallDir\SKILL.md"
            Write-Host '  3. OpenCode reads from ~\.config\opencode\skills\ automatically.'
        }
        'roo-code' {
            Write-Host 'To activate the skill in Roo Code:'
            Write-Host '  1. Open your project in VS Code with Roo Code.'
            Write-Host '  2. The rule is loaded from:'
            Write-Host "     $InstallDir\$SkillName.md"
            Write-Host '  3. Roo Code will pick up the rule automatically.'
        }
        'antigravity' {
            Write-Host 'To activate the skill in Antigravity:'
            Write-Host '  1. Open your project.'
            Write-Host '  2. The skill is available at:'
            Write-Host "     $InstallDir\SKILL.md"
            Write-Host '  3. Antigravity reads from .agents\skills\ automatically.'
        }
        'universal' {
            Write-Host 'The skill is installed at the universal path:'
            Write-Host "  $InstallDir\SKILL.md"
            Write-Host ''
            Write-Host 'Tools that read ~\.agents\skills\ (Codex CLI, Gemini CLI,'
            Write-Host 'Kiro, Antigravity, and others) will discover it automatically.'
        }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Install for a single platform / all platforms
# ---------------------------------------------------------------------------
function Install-Single {
    $plat = Resolve-Platform
    $installDir = Resolve-InstallDir -Plat $plat -ProjectLevel ([bool]$Project) -CustomPath $Path
    Write-Info "Install directory: $installDir"

    Copy-SkillFiles -InstallDir $installDir
    Invoke-Adapters -Plat $plat -InstallDir $installDir -ProjectLevel ([bool]$Project)
    Install-UniversalSecondary -Plat $plat -InstallDir $installDir
    Show-ActivationInstructions -Plat $plat -InstallDir $installDir -ProjectLevel ([bool]$Project)

    if ($DryRun) {
        Write-Info 'Dry run complete. No changes were made.'
    } else {
        Write-Ok "Skill '$SkillName' installed successfully for $plat."
    }
}

function Install-All {
    $platforms = Get-AllDetectedPlatforms
    Write-Info ("Installing to all detected platforms: {0}" -f ($platforms -join ', '))
    Write-Host '----------------------------------------'

    $count = 0
    $firstNonAgents = $null
    foreach ($plat in $platforms) {
        Write-Host ''
        Write-Info "--- Installing for: $plat ---"
        $installDir = Resolve-InstallDir -Plat $plat -ProjectLevel ([bool]$Project) -CustomPath $Path
        Write-Info "Install directory: $installDir"
        Copy-SkillFiles -InstallDir $installDir
        Invoke-Adapters -Plat $plat -InstallDir $installDir -ProjectLevel ([bool]$Project)
        $count++
        if ($null -eq $firstNonAgents -and $plat -notin @('codex','antigravity','universal')) {
            $firstNonAgents = $installDir
        }
    }

    if ($null -ne $firstNonAgents) {
        # Use a representative platform name for the secondary call (any non-skip platform).
        Install-UniversalSecondary -Plat 'claude-code' -InstallDir $firstNonAgents
    }

    Write-Host ''
    if ($DryRun) {
        Write-Info 'Dry run complete. No changes were made.'
    } else {
        Write-Ok "Skill '$SkillName' installed to $count platform(s)."
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host "Installing skill: $SkillName" -ForegroundColor White
Write-Host '----------------------------------------'

Test-SkillMd

if ($All) { Install-All } else { Install-Single }

exit 0
