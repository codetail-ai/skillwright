<#
.SYNOPSIS
    One-liner bootstrap for skillwright on Windows (port of bootstrap.sh).

.DESCRIPTION
    Clones skillwright to ~/.agents/skills/ and links it into all detected
    global platforms.

    Distributed for `iwr | iex`:
        iwr -useb https://raw.githubusercontent.com/codetail-ai/skillwright/main/scripts/bootstrap.ps1 | iex

    `iex` on a downloaded string runs in the current scope and bypasses
    PowerShell execution policy, which is the standard install pattern on
    Windows (used by Chocolatey, Scoop, oh-my-posh, etc.).

.NOTES
    Targets PowerShell 5.1 (built into Windows 10/11). Requires `git` on PATH.
    Self-contained on purpose -- helpers are duplicated rather than imported,
    because this file is downloaded and piped to `iex`. See
    docs/windows-support.md.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$RepoUrl      = 'https://github.com/codetail-ai/skillwright.git'
$SkillName    = 'skillwright'
$CanonicalDir = "$HOME\.agents\skills\$SkillName"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:UseColor = $Host.UI.RawUI -and -not [Console]::IsOutputRedirected
function Write-Info    { param([string]$Message) if ($script:UseColor) { Write-Host '[INFO]  ' -ForegroundColor Blue -NoNewline } else { Write-Host '[INFO]  ' -NoNewline }; Write-Host $Message }
function Write-Ok      { param([string]$Message) if ($script:UseColor) { Write-Host '[OK]    ' -ForegroundColor Green -NoNewline } else { Write-Host '[OK]    ' -NoNewline }; Write-Host $Message }
function Write-WarnMsg { param([string]$Message) if ($script:UseColor) { Write-Host '[WARN]  ' -ForegroundColor Yellow -NoNewline } else { Write-Host '[WARN]  ' -NoNewline }; Write-Host $Message }

# ---------------------------------------------------------------------------
# Detect globally-installed platforms (user-level only).
# Returns a list of platform tokens (claude-code, gemini, ...).
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

function Get-PlatformInstallPath {
    param([string]$Platform)
    switch ($Platform) {
        'claude-code' { "$HOME\.claude\skills\$SkillName" }
        'gemini'      { "$HOME\.gemini\skills\$SkillName" }
        'goose'       { "$HOME\.config\goose\skills\$SkillName" }
        'opencode'    { "$HOME\.config\opencode\skills\$SkillName" }
        'copilot'     { "$HOME\.copilot\skills\$SkillName" }
        default       { $null }
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
        default       { $Platform        }
    }
}

# ---------------------------------------------------------------------------
# Three-tier link: SymbolicLink -> Junction -> Copy. See docs/windows-support.md.
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
    Write-WarnMsg "  This breaks 'git pull' auto-update -- re-run bootstrap to refresh."
    Write-WarnMsg "  Tip: enable Developer Mode (Settings -> For developers) to fix this."
    Copy-Item -LiteralPath $Target -Destination $LinkPath -Recurse -Force
    return 'copy'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Skillwright -- Bootstrap Installer' -ForegroundColor White
Write-Host ''

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-WarnMsg 'git is not installed or not on PATH. Install Git for Windows and retry.'
    exit 1
}

# Clone or update the canonical location.
if (Test-Path -LiteralPath (Join-Path $CanonicalDir '.git') -PathType Container) {
    Write-Info "Updating existing install at $CanonicalDir"
    Push-Location -LiteralPath $CanonicalDir
    try {
        git pull --ff-only 2>$null | Out-Null
    } catch {
        # Non-fatal -- mirror shell behaviour (`|| true`).
    } finally {
        Pop-Location
    }
} else {
    Write-Info "Cloning $SkillName to $CanonicalDir"
    $parent = Split-Path -Parent $CanonicalDir
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $CanonicalDir) {
        Remove-Item -LiteralPath $CanonicalDir -Recurse -Force
    }
    git clone $RepoUrl $CanonicalDir
    if ($LASTEXITCODE -ne 0) {
        Write-WarnMsg "git clone failed (exit $LASTEXITCODE)."
        exit 1
    }
}

Write-Ok "Installed at $CanonicalDir"

# Detect platforms and link.
$platforms = Get-DetectedGlobalPlatforms
$installed = New-Object System.Collections.Generic.List[string]

foreach ($plat in $platforms) {
    $dest = Get-PlatformInstallPath -Platform $plat
    $name = Get-PlatformDisplayName -Platform $plat
    $tier = New-SkillLink -Target $CanonicalDir -LinkPath $dest
    Write-Ok "Linked for $name ($tier) -> $dest"
    $installed.Add($name) | Out-Null
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Done!' -ForegroundColor White
Write-Host ''
Write-Host "  Canonical location: $CanonicalDir"

if ($installed.Count -gt 0) {
    Write-Host ("  Linked to {0} platform(s): {1}" -f $installed.Count, ($installed -join ', '))
}

Write-Host ''
Write-Host 'How to use:'
Write-Host '  Open your AI agent and type:'
Write-Host '    /skillwright <describe your workflow>'
Write-Host ''
Write-Host '  To update later:'
Write-Host "    cd $CanonicalDir; git pull"
Write-Host ''

if ($installed.Count -eq 0) {
    Write-WarnMsg 'No global platforms detected. The skill is installed at the universal path.'
    Write-Host '  Tools like Codex CLI, Gemini CLI, Kiro, and Antigravity'
    Write-Host '  read from ~/.agents/skills/ automatically.'
    Write-Host ''
}
