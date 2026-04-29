<#
.SYNOPSIS
    Install any skill (git URL or local path) to all detected platforms on Windows.

.DESCRIPTION
    PowerShell port of install-skill.sh. Three-tier link fallback
    (SymbolicLink -> Junction -> Copy). See docs/windows-support.md.

.PARAMETER Source
    Git URL (https://... or *.git) or local directory path. Required (positional).

.PARAMETER Platform
    Install to a specific platform only. One of: claude-code, copilot, cursor,
    windsurf, cline, codex, gemini, kiro, trae, goose, opencode, roo-code,
    antigravity, universal.

.PARAMETER Project
    Use project-level paths (current directory) instead of user-level.

.PARAMETER All
    Install to every detected platform (default behaviour when -Platform is omitted).

.PARAMETER DryRun
    Preview without making changes.

.PARAMETER Uninstall
    Remove the skill from all platforms.

.EXAMPLE
    .\install-skill.ps1 https://github.com/someone/sales-report-skill.git
    .\install-skill.ps1 .\sales-report-skill
    .\install-skill.ps1 .\sales-report-skill -Platform cursor -Project
    .\install-skill.ps1 .\sales-report-skill -DryRun
    .\install-skill.ps1 .\sales-report-skill -Uninstall

.NOTES
    Targets PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)] [string] $Source,
    [string] $Platform,
    [switch] $Project,
    [switch] $All,
    [switch] $DryRun,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:UseColor = $Host.UI.RawUI -and -not [Console]::IsOutputRedirected
function Write-Info    { param([string]$Message) if ($script:UseColor) { Write-Host '[INFO]  ' -ForegroundColor Blue -NoNewline } else { Write-Host '[INFO]  ' -NoNewline }; Write-Host $Message }
function Write-Ok      { param([string]$Message) if ($script:UseColor) { Write-Host '[OK]    ' -ForegroundColor Green -NoNewline } else { Write-Host '[OK]    ' -NoNewline }; Write-Host $Message }
function Write-WarnMsg { param([string]$Message) if ($script:UseColor) { Write-Host '[WARN]  ' -ForegroundColor Yellow -NoNewline } else { Write-Host '[WARN]  ' -NoNewline }; Write-Host $Message }
function Write-Err     { param([string]$Message) if ($script:UseColor) { Write-Host '[ERROR] ' -ForegroundColor Red -NoNewline } else { Write-Host '[ERROR] ' -NoNewline }; Write-Host $Message }

# PS 5.1 quirk: Set-Content -Encoding UTF8 emits a BOM, which can break
# Markdown frontmatter parsers and corrupts Add-Content append flows.
# Use raw .NET to write BOM-less UTF-8.
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
# Source resolution
# ---------------------------------------------------------------------------
function Test-IsGitUrl {
    param([string]$S)
    return ($S -match '://' -or $S.EndsWith('.git'))
}

function Resolve-Source {
    if (Test-IsGitUrl $Source) {
        $skillBase = [System.IO.Path]::GetFileNameWithoutExtension($Source.TrimEnd('/'))
        if ([string]::IsNullOrEmpty($skillBase)) {
            $skillBase = (Split-Path -Leaf $Source) -replace '\.git$', ''
        }
        $canonical = "$HOME\.agents\skills\$skillBase"

        if (Test-Path -LiteralPath (Join-Path $canonical '.git') -PathType Container) {
            Write-Info "Updating existing install at $canonical"
            if (-not $DryRun) {
                Push-Location -LiteralPath $canonical
                try { git pull --ff-only 2>$null | Out-Null } catch { } finally { Pop-Location }
            }
        } else {
            Write-Info "Cloning $Source"
            if (-not $DryRun) {
                $parent = Split-Path -Parent $canonical
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                if (Test-Path -LiteralPath $canonical) { Remove-Item -LiteralPath $canonical -Recurse -Force }
                git clone $Source $canonical
                if ($LASTEXITCODE -ne 0) { Write-Err "git clone failed (exit $LASTEXITCODE)"; exit 1 }
            }
        }
        return $canonical
    }

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Err "Source directory not found: $Source"
        exit 1
    }
    return (Resolve-Path -LiteralPath $Source).Path
}

# ---------------------------------------------------------------------------
# Read SKILL.md frontmatter (returns hashtable of name -> value).
#   Mirrors the awk + sed extraction in install-skill.sh.
#   Limitations: same as the shell version -- single-line values only,
#   strips surrounding single/double quotes from `name`.
# ---------------------------------------------------------------------------
function Read-SkillFrontmatter {
    param([Parameter(Mandatory)] [string] $SkillMdPath)

    $result = @{}
    if (-not (Test-Path -LiteralPath $SkillMdPath)) { return $result }

    $inFm = $false
    $lineNum = 0
    foreach ($line in (Get-Content -LiteralPath $SkillMdPath)) {
        $lineNum++
        if ($lineNum -eq 1) {
            if ($line -eq '---') { $inFm = $true }
            continue
        }
        if ($inFm -and $line -eq '---') { break }
        if (-not $inFm) { continue }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
            $key = $matches[1]
            $val = $matches[2]
            # Strip optional surrounding quotes
            if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $matches[1] }
            $result[$key] = $val
        }
    }
    return $result
}

# Extract body (everything after the closing --- of frontmatter).
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
    if ($bodyStart -lt 0) { return '' }
    if ($bodyStart -ge $lines.Count) { return '' }
    return ($lines[$bodyStart..($lines.Count - 1)] -join "`n")
}

# ---------------------------------------------------------------------------
# Validate SKILL.md exists at the source
# ---------------------------------------------------------------------------
function Test-Source {
    param([string]$SourceDir)
    $skillMd = Join-Path $SourceDir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd)) {
        Write-Err "No SKILL.md found in $SourceDir"
        Write-Err "A valid skill must contain a SKILL.md file."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Platform detection (global and project-level)
# ---------------------------------------------------------------------------
function Get-DetectedGlobalPlatforms {
    $detected = @()
    if (Test-Path -LiteralPath "$HOME\.claude"          -PathType Container) { $detected += 'claude-code' }
    if (Test-Path -LiteralPath "$HOME\.gemini"          -PathType Container) { $detected += 'gemini'      }
    if (Test-Path -LiteralPath "$HOME\.config\goose"    -PathType Container) { $detected += 'goose'       }
    if (Test-Path -LiteralPath "$HOME\.config\opencode" -PathType Container) { $detected += 'opencode'    }
    if (Test-Path -LiteralPath "$HOME\.copilot"         -PathType Container) { $detected += 'copilot'     }
    return $detected
}

function Get-DetectedProjectPlatforms {
    $detected = @()
    if (Test-Path -LiteralPath '.cursor'    -PathType Container) { $detected += 'cursor'   }
    if (Test-Path -LiteralPath '.windsurf'  -PathType Container) { $detected += 'windsurf' }
    if ((Test-Path -LiteralPath '.clinerules' -PathType Container) -or (Test-Path -LiteralPath '.cline' -PathType Container)) { $detected += 'cline' }
    if (Test-Path -LiteralPath '.kiro'      -PathType Container) { $detected += 'kiro'    }
    if (Test-Path -LiteralPath '.trae'      -PathType Container) { $detected += 'trae'    }
    if (Test-Path -LiteralPath '.roo'       -PathType Container) { $detected += 'roo-code'}
    if (Test-Path -LiteralPath '.github'    -PathType Container) { $detected += 'copilot' }
    return $detected
}

function Resolve-PlatformPath {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [bool]   $ProjectLevel
    )

    if ($ProjectLevel) {
        switch ($Platform) {
            'claude-code' { ".claude\skills\$Name" }
            'copilot'     { ".github\skills\$Name" }
            'cursor'      { ".cursor\rules\$Name"  }
            'windsurf'    { ".windsurf\rules\$Name"}
            'cline'       { ".clinerules\$Name"    }
            'gemini'      { ".gemini\skills\$Name" }
            'kiro'        { ".kiro\skills\$Name"   }
            'trae'        { ".trae\rules\$Name"    }
            'roo-code'    { ".roo\rules\$Name"     }
            'goose'       { ".agents\skills\$Name" }
            'opencode'    { ".agents\skills\$Name" }
            default       { ".agents\skills\$Name" }
        }
    } else {
        switch ($Platform) {
            'claude-code' { "$HOME\.claude\skills\$Name"          }
            'copilot'     { "$HOME\.copilot\skills\$Name"         }
            'cursor'      { "$HOME\.cursor\rules\$Name"           }
            'windsurf'    { "$HOME\.codeium\windsurf\skills\$Name"}
            'cline'       { "$HOME\.cline\rules\$Name"            }
            'gemini'      { "$HOME\.gemini\skills\$Name"          }
            'goose'       { "$HOME\.config\goose\skills\$Name"    }
            'opencode'    { "$HOME\.config\opencode\skills\$Name" }
            'kiro'        { "$HOME\.agents\skills\$Name"          }
            'trae'        { "$HOME\.agents\skills\$Name"          }
            'roo-code'    { "$HOME\.agents\skills\$Name"          }
            default       { "$HOME\.agents\skills\$Name"          }
        }
    }
}

function Get-PlatformDisplayName {
    param([string]$Platform)
    switch ($Platform) {
        'claude-code' { 'Claude Code'    }
        'gemini'      { 'Gemini CLI'     }
        'goose'       { 'Goose'          }
        'opencode'    { 'OpenCode'       }
        'copilot'     { 'GitHub Copilot' }
        'cursor'      { 'Cursor'         }
        'windsurf'    { 'Windsurf'       }
        'cline'       { 'Cline'          }
        'kiro'        { 'Kiro'           }
        'trae'        { 'Trae'           }
        'roo-code'    { 'Roo Code'       }
        default       { $Platform        }
    }
}

# ---------------------------------------------------------------------------
# Format adapters (Tier 2 platforms: Cursor .mdc, Windsurf rules, plain MD).
# ---------------------------------------------------------------------------
function Invoke-CursorMdcAdapter {
    param(
        [string] $TargetDir,
        [string] $SourceDir,
        [string] $SkillName
    )
    $skillMd = Join-Path $SourceDir 'SKILL.md'
    $fm = Read-SkillFrontmatter -SkillMdPath $skillMd
    $desc = if ($fm.ContainsKey('description')) { $fm['description'] } else { '' }
    $mdcFile = Join-Path $TargetDir "$SkillName.mdc"

    if ($DryRun) {
        Write-Info "[dry-run] Would generate Cursor .mdc: $mdcFile"
        return
    }

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    $body = Get-SkillBody -SkillMdPath $skillMd
    $content = @"
---
description: $desc
globs:
alwaysApply: true
---
$body
"@
    Write-Utf8NoBom -Path $mdcFile -Content $content
    Write-Ok "Generated Cursor .mdc: $mdcFile"
}

function Invoke-WindsurfRuleAdapter {
    param(
        [string] $TargetDir,
        [bool]   $IsGlobal,
        [string] $SourceDir,
        [string] $SkillName
    )
    $skillMd = Join-Path $SourceDir 'SKILL.md'
    $body = Get-SkillBody -SkillMdPath $skillMd

    if ($IsGlobal) {
        $globalFile = "$HOME\.codeium\windsurf\memories\global_rules.md"
        if ($DryRun) {
            Write-Info "[dry-run] Would append to Windsurf global_rules.md: $globalFile"
            return
        }

        $globalDir = Split-Path -Parent $globalFile
        if (-not (Test-Path -LiteralPath $globalDir)) {
            New-Item -ItemType Directory -Path $globalDir -Force | Out-Null
        }

        # Idempotent: strip existing block bracketed by markers, then append.
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
        if ($DryRun) {
            Write-Info "[dry-run] Would generate Windsurf rule: $ruleFile"
            return
        }
        if (-not (Test-Path -LiteralPath $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        }
        Write-Utf8NoBom -Path $ruleFile -Content $body
        Write-Ok "Generated Windsurf rule: $ruleFile"
    }
}

function Invoke-PlainRuleAdapter {
    param(
        [string] $TargetDir,
        [string] $Filename,
        [string] $SourceDir
    )
    $skillMd = Join-Path $SourceDir 'SKILL.md'
    $plainFile = Join-Path $TargetDir $Filename

    if ($DryRun) {
        Write-Info "[dry-run] Would generate plain rule: $plainFile"
        return
    }

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    $body = Get-SkillBody -SkillMdPath $skillMd
    Write-Utf8NoBom -Path $plainFile -Content $body
    Write-Ok "Generated plain rule: $plainFile"
}

function Invoke-Adapters {
    param(
        [string] $Platform,
        [string] $Dest,
        [string] $SourceDir,
        [string] $SkillName,
        [bool]   $ProjectLevel
    )
    switch ($Platform) {
        'cursor' { Invoke-CursorMdcAdapter -TargetDir $Dest -SourceDir $SourceDir -SkillName $SkillName }
        'windsurf' {
            if ($ProjectLevel) {
                $rulesDir = Join-Path (Get-Location).Path '.windsurf\rules'
                Invoke-WindsurfRuleAdapter -TargetDir $rulesDir -IsGlobal $false -SourceDir $SourceDir -SkillName $SkillName
            } else {
                Invoke-WindsurfRuleAdapter -TargetDir '' -IsGlobal $true -SourceDir $SourceDir -SkillName $SkillName
            }
        }
        'cline'    { Invoke-PlainRuleAdapter -TargetDir $Dest -Filename "$SkillName.md" -SourceDir $SourceDir }
        'roo-code' { Invoke-PlainRuleAdapter -TargetDir $Dest -Filename "$SkillName.md" -SourceDir $SourceDir }
        'trae'     { Invoke-PlainRuleAdapter -TargetDir $Dest -Filename "$SkillName.md" -SourceDir $SourceDir }
    }
}

# ---------------------------------------------------------------------------
# Three-tier link
# ---------------------------------------------------------------------------
function New-SkillLink {
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $LinkPath
    )

    if ($Target -eq $LinkPath) { return 'noop' }

    $parent = Split-Path -Parent $LinkPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Remove-Item -LiteralPath $LinkPath -Recurse -Force
    }

    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null
        return 'symlink'
    } catch { }

    if (Test-Path -LiteralPath $Target -PathType Container) {
        try {
            New-Item -ItemType Junction -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null
            return 'junction'
        } catch { }
    }

    Write-WarnMsg "Could not create symlink or junction for $LinkPath. Falling back to file copy."
    Copy-Item -LiteralPath $Target -Destination $LinkPath -Recurse -Force
    return 'copy'
}

# ---------------------------------------------------------------------------
# Install to a single platform
# ---------------------------------------------------------------------------
function Install-ToPlatform {
    param(
        [string] $Plat,
        [string] $SourceDir,
        [string] $SkillName,
        [bool]   $ProjectLevel
    )
    $dest    = Resolve-PlatformPath -Platform $Plat -Name $SkillName -ProjectLevel $ProjectLevel
    $display = Get-PlatformDisplayName -Platform $Plat

    if ($DryRun) {
        Write-Info "[dry-run] Would install to ${display}: $dest"
        Invoke-Adapters -Platform $Plat -Dest $dest -SourceDir $SourceDir -SkillName $SkillName -ProjectLevel $ProjectLevel
        return
    }

    $tier = New-SkillLink -Target $SourceDir -LinkPath $dest
    Write-Ok "Installed for $display ($tier) -> $dest"
    Invoke-Adapters -Platform $Plat -Dest $dest -SourceDir $SourceDir -SkillName $SkillName -ProjectLevel $ProjectLevel
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
function Invoke-Uninstall {
    param([string] $SkillName)

    Write-Host ''
    Write-Host "Uninstalling skill: $SkillName" -ForegroundColor White
    Write-Host ''

    $canonical = "$HOME\.agents\skills\$SkillName"
    if (Test-Path -LiteralPath $canonical) {
        if ($DryRun) {
            Write-Info "[dry-run] Would remove: $canonical"
        } else {
            Remove-Item -LiteralPath $canonical -Recurse -Force
            Write-Ok "Removed: $canonical"
        }
    }

    foreach ($plat in @('claude-code','gemini','goose','opencode','copilot')) {
        $dest = Resolve-PlatformPath -Platform $plat -Name $SkillName -ProjectLevel $false
        if (Test-Path -LiteralPath $dest) {
            if ($DryRun) {
                Write-Info "[dry-run] Would remove: $dest"
            } else {
                Remove-Item -LiteralPath $dest -Recurse -Force
                Write-Ok "Removed: $dest ($(Get-PlatformDisplayName -Platform $plat))"
            }
        }
    }

    foreach ($plat in @('cursor','windsurf','cline','kiro','trae','roo-code','copilot')) {
        $dest = Resolve-PlatformPath -Platform $plat -Name $SkillName -ProjectLevel $true
        if (Test-Path -LiteralPath $dest) {
            if ($DryRun) {
                Write-Info "[dry-run] Would remove: $dest"
            } else {
                Remove-Item -LiteralPath $dest -Recurse -Force
                Write-Ok "Removed: $dest ($(Get-PlatformDisplayName -Platform $plat))"
            }
        }
    }

    Write-Host ''
    Write-Host 'Done.'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Universal Skill Installer' -ForegroundColor White
Write-Host ''

$sourceDir = Resolve-Source

# Validate (skip on dry-run if source dir doesn't exist yet, e.g. would-be clone).
if (-not $DryRun -or (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    Test-Source -SourceDir $sourceDir
}

# Resolve skill name from SKILL.md frontmatter or directory basename.
$fm = Read-SkillFrontmatter -SkillMdPath (Join-Path $sourceDir 'SKILL.md')
$skillName = if ($fm.ContainsKey('name') -and -not [string]::IsNullOrWhiteSpace($fm['name'])) {
    $fm['name']
} else {
    Split-Path -Leaf $sourceDir
}

Write-Info "Skill: $skillName"
Write-Info "Source: $sourceDir"

if ($Uninstall) {
    Invoke-Uninstall -SkillName $skillName
    exit 0
}

# Install to canonical (if not already there).
$canonical = "$HOME\.agents\skills\$skillName"
if ((-not (Test-IsGitUrl $Source)) -and ($sourceDir -ne $canonical)) {
    if ($DryRun) {
        Write-Info "[dry-run] Would copy to canonical: $canonical"
    } else {
        $parent = Split-Path -Parent $canonical
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if (Test-Path -LiteralPath $canonical) {
            Remove-Item -LiteralPath $canonical -Recurse -Force
        }
        Copy-Item -LiteralPath $sourceDir -Destination $canonical -Recurse -Force
        Write-Ok "Copied to canonical: $canonical"
    }
}

# Determine which platforms to install to.
$projectLevel = [bool]$Project
if ($Platform) {
    Install-ToPlatform -Plat $Platform -SourceDir $sourceDir -SkillName $skillName -ProjectLevel $projectLevel
} else {
    $platforms = if ($projectLevel) { Get-DetectedProjectPlatforms } else { Get-DetectedGlobalPlatforms }
    $count = 0
    foreach ($plat in $platforms) {
        Install-ToPlatform -Plat $plat -SourceDir $sourceDir -SkillName $skillName -ProjectLevel $projectLevel
        $count++
    }
    if ($count -eq 0) {
        Write-WarnMsg 'No platforms detected. Skill installed at canonical path only.'
    }
}

# Summary
Write-Host ''
Write-Host 'Done!' -ForegroundColor White
Write-Host "  Canonical: $canonical"
Write-Host "  Invoke with: /$skillName"
Write-Host ''

if ($DryRun) {
    Write-Host 'Dry run -- no changes made.' -ForegroundColor Yellow
    Write-Host ''
}
