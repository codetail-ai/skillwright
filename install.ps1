<#
.SYNOPSIS
    Symlink skillwright to all detected global platforms (Windows port of install.sh).

.DESCRIPTION
    For users who already cloned the repo. Creates symlinks (or junctions, or
    copies) so `git pull` in the cloned directory updates all tools automatically.

    Tier 1: SymbolicLink  (requires Developer Mode or admin)
    Tier 2: Junction      (works for any user; same volume only)
    Tier 3: Copy          (last resort; breaks the auto-update loop)

.PARAMETER DryRun
    Preview without making changes.

.PARAMETER Uninstall
    Remove all links pointing to this repo.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall

.NOTES
    Targets PowerShell 5.1 (built into Windows 10/11). See
    docs/windows-support.md for the full design rationale.
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$SkillName = 'skillwright'
$RepoDir   = (Resolve-Path -LiteralPath $PSScriptRoot).Path

# ---------------------------------------------------------------------------
# Logging helpers (color when stdout is a terminal)
# ---------------------------------------------------------------------------
$script:UseColor = $Host.UI.RawUI -and -not [Console]::IsOutputRedirected

function Write-Info    { param([string]$Message) if ($script:UseColor) { Write-Host '[INFO]  ' -ForegroundColor Blue -NoNewline } else { Write-Host '[INFO]  ' -NoNewline }; Write-Host $Message }
function Write-Ok      { param([string]$Message) if ($script:UseColor) { Write-Host '[OK]    ' -ForegroundColor Green -NoNewline } else { Write-Host '[OK]    ' -NoNewline }; Write-Host $Message }
function Write-WarnMsg { param([string]$Message) if ($script:UseColor) { Write-Host '[WARN]  ' -ForegroundColor Yellow -NoNewline } else { Write-Host '[WARN]  ' -NoNewline }; Write-Host $Message }
function Write-Err     { param([string]$Message) if ($script:UseColor) { Write-Host '[ERROR] ' -ForegroundColor Red -NoNewline } else { Write-Host '[ERROR] ' -NoNewline }; Write-Host $Message -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# All global platform paths (user-level only)
#   Mirrors all_platform_entries() in install.sh.
# ---------------------------------------------------------------------------
function Get-PlatformEntries {
    @(
        [pscustomobject]@{ DetectDir = "$HOME\.claude";         InstallPath = "$HOME\.claude\skills\$SkillName";        Display = 'Claude Code'    }
        [pscustomobject]@{ DetectDir = "$HOME\.gemini";         InstallPath = "$HOME\.gemini\skills\$SkillName";        Display = 'Gemini CLI'     }
        [pscustomobject]@{ DetectDir = "$HOME\.config\goose";   InstallPath = "$HOME\.config\goose\skills\$SkillName";  Display = 'Goose'          }
        [pscustomobject]@{ DetectDir = "$HOME\.config\opencode";InstallPath = "$HOME\.config\opencode\skills\$SkillName";Display = 'OpenCode'      }
        [pscustomobject]@{ DetectDir = "$HOME\.copilot";        InstallPath = "$HOME\.copilot\skills\$SkillName";       Display = 'GitHub Copilot' }
    )
}

# ---------------------------------------------------------------------------
# Create a symlink with three-tier fallback (symlink -> junction -> copy).
# Returns 'symlink', 'junction', or 'copy' to indicate which tier succeeded.
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

    # Remove existing entry (file, link, or directory).
    # Get-Item with -Force surfaces broken/orphaned reparse points that Test-Path misses.
    $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Remove-Item -LiteralPath $LinkPath -Recurse -Force
    }

    # Tier 1: real symbolic link (needs Dev Mode or admin)
    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null
        return 'symlink'
    } catch { }

    # Tier 2: directory junction (no privileges, same volume only)
    if (Test-Path -LiteralPath $Target -PathType Container) {
        try {
            New-Item -ItemType Junction -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null
            return 'junction'
        } catch { }
    }

    # Tier 3: copy fallback -- breaks auto-update via `git pull`
    Write-WarnMsg "Could not create symlink or junction for $LinkPath. Falling back to file copy."
    Write-WarnMsg "  This breaks the auto-update loop -- running 'git pull' in the source repo will NOT propagate."
    Write-WarnMsg "  Re-run install.ps1 to refresh, or enable Developer Mode (Settings -> For developers)."
    Copy-Item -LiteralPath $Target -Destination $LinkPath -Recurse -Force
    return 'copy'
}

# ---------------------------------------------------------------------------
# Test whether a path is a link (symlink or junction) pointing at our repo.
# ---------------------------------------------------------------------------
function Test-LinkPointsAt {
    param(
        [Parameter(Mandatory)] [string] $LinkPath,
        [Parameter(Mandatory)] [string] $ExpectedTarget
    )
    $item = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if ($item.LinkType -notin @('SymbolicLink', 'Junction')) { return $false }

    # $item.Target is an array on PS 5.1+. Normalise paths for comparison.
    $expected = (Resolve-Path -LiteralPath $ExpectedTarget -ErrorAction SilentlyContinue).Path
    if (-not $expected) { $expected = $ExpectedTarget }

    foreach ($t in @($item.Target)) {
        if ([string]::IsNullOrEmpty($t)) { continue }
        $resolved = $null
        try { $resolved = (Resolve-Path -LiteralPath $t -ErrorAction Stop).Path } catch { $resolved = $t }
        if ($resolved -eq $expected) { return $true }
        if ($t -eq $ExpectedTarget) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Uninstall: remove links pointing to RepoDir
# ---------------------------------------------------------------------------
function Invoke-Uninstall {
    Write-Host ''
    Write-Host 'Uninstalling skillwright links' -ForegroundColor White
    Write-Host ''

    $canonical = "$HOME\.agents\skills\$SkillName"

    if (Test-LinkPointsAt -LinkPath $canonical -ExpectedTarget $RepoDir) {
        if ($DryRun) {
            Write-Info "[dry-run] Would remove: $canonical"
        } else {
            Remove-Item -LiteralPath $canonical -Recurse -Force
            Write-Ok "Removed: $canonical"
        }
    }

    foreach ($entry in Get-PlatformEntries) {
        if (Test-LinkPointsAt -LinkPath $entry.InstallPath -ExpectedTarget $RepoDir) {
            if ($DryRun) {
                Write-Info "[dry-run] Would remove: $($entry.InstallPath)"
            } else {
                Remove-Item -LiteralPath $entry.InstallPath -Recurse -Force
                Write-Ok "Removed: $($entry.InstallPath) ($($entry.Display))"
            }
        }
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host 'Dry run -- no changes made.' -ForegroundColor Yellow
    } else {
        Write-Host ''
        Write-Host 'Done. Links removed.'
    }
}

# ---------------------------------------------------------------------------
# Install: create links to all detected platforms
# ---------------------------------------------------------------------------
function Invoke-Install {
    Write-Host ''
    Write-Host 'Skillwright -- Symlink Installer' -ForegroundColor White
    Write-Host ''
    Write-Info "Source: $RepoDir"

    # Always install to canonical location
    $canonical = "$HOME\.agents\skills\$SkillName"
    if ($DryRun) {
        Write-Info "[dry-run] Would link: $canonical -> $RepoDir"
    } else {
        $tier = New-SkillLink -Target $RepoDir -LinkPath $canonical
        Write-Ok "Canonical ($tier): $canonical"
    }

    foreach ($entry in Get-PlatformEntries) {
        if (Test-Path -LiteralPath $entry.DetectDir -PathType Container) {
            if ($DryRun) {
                Write-Info "[dry-run] Would link: $($entry.InstallPath) -> $RepoDir ($($entry.Display))"
            } else {
                $tier = New-SkillLink -Target $RepoDir -LinkPath $entry.InstallPath
                Write-Ok "Linked for $($entry.Display) ($tier) -> $($entry.InstallPath)"
            }
        }
    }

    Write-Host ''
    Write-Host 'Done!' -ForegroundColor White
    Write-Host ''

    if ($DryRun) {
        Write-Host 'Dry run -- no changes made.' -ForegroundColor Yellow
        Write-Host ''
    } else {
        Write-Host "  Links point to: $RepoDir"
        Write-Host "  Run 'git pull' from that directory to update all tools."
        Write-Host ''
    }

    Write-Host 'How to use:'
    Write-Host '  Open your AI agent and type:'
    Write-Host '    /skillwright <describe your workflow>'
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Invoke-Uninstall
} else {
    Invoke-Install
}
