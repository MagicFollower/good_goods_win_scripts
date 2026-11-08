<#
.SYNOPSIS
    IDEA Configuration Backup Script
.DESCRIPTION
    Backs up IntelliJ IDEA 2025.3 configuration and bookmarks.
    Supports interactive menu mode (-Interactive) and direct mode (-Mode).
.PARAMETER Interactive
    Launch interactive menu.
.PARAMETER Mode
    Backup mode: BookmarksOnly / Lean / Full / All
.PARAMETER BackupRoot
    Backup destination root folder.
.PARAMETER IncludePlugins
    Include plugins/ directory (large, ~550 MB).
.EXAMPLE
    .\Backup-IDEAConfig.ps1 -Interactive
    .\Backup-IDEAConfig.ps1 -Mode BookmarksOnly
    .\Backup-IDEAConfig.ps1 -Mode Lean
#>
param(
    [switch]$Interactive,
    [ValidateSet("Full", "BookmarksOnly", "All", "Lean")]
    [string]$Mode = "Lean",
    [string]$BackupRoot = "D:\Code\WorkSpace\.qoder\idea-backups",
    [switch]$IncludePlugins
)

$ErrorActionPreference = "Stop"

# ============================================================
#  Constants
# ============================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$IdeaVersion = "IntelliJIdea2025.3"
$RoamingDir = Join-Path $env:APPDATA "JetBrains\$IdeaVersion"
$WorkspaceDir = Join-Path $RoamingDir "workspace"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# ============================================================
#  Helper: Draw a horizontal rule
# ============================================================
function Write-Rule {
    param([string]$Char = "-", [int]$Width = 64, [ConsoleColor]$Color = "DarkGray")
    Write-Host ("  " + ($Char * $Width)) -ForegroundColor $Color
}

# ============================================================
#  Helper: Draw a banner
# ============================================================
function Write-Banner {
    Write-Host ""
    Write-Host "  +----------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |                                                                |" -ForegroundColor Cyan
    Write-Host "  |          IntelliJ IDEA  Configuration Backup Tool              |" -ForegroundColor Cyan
    Write-Host "  |                    2025.3  |  Windows                         |" -ForegroundColor Cyan
    Write-Host "  |                                                                |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
#  Helper: Show menu and get choice
# ============================================================
function Show-Menu {
    Write-Banner

    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  Select backup mode:                                         |" -ForegroundColor Yellow
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |                                                              |" -ForegroundColor White
    Write-Host "  |  [1] Bookmarks Only                                          |" -ForegroundColor White
    Write-Host "  |      Extract bookmarks from all projects as XML files        |" -ForegroundColor Gray
    Write-Host "  |      Size: ~10 KB   Speed: instant                           |" -ForegroundColor DarkGray
    Write-Host "  |                                                              |" -ForegroundColor White
    Write-Host "  |  [2] Lean Backup (Recommended)                               |" -ForegroundColor White
    Write-Host "  |      Bookmarks + All config (exclude plugin JARs)            |" -ForegroundColor Gray
    Write-Host "  |      Size: ~10 MB   Speed: a few seconds                     |" -ForegroundColor DarkGray
    Write-Host "  |                                                              |" -ForegroundColor White
    Write-Host "  |  [3] Full Backup                                             |" -ForegroundColor White
    Write-Host "  |      Bookmarks + All config + Plugin JARs                    |" -ForegroundColor Gray
    Write-Host "  |      Size: ~560 MB  Speed: 1-2 minutes                       |" -ForegroundColor DarkGray
    Write-Host "  |                                                              |" -ForegroundColor White
    Write-Host "  |  [4] Complete Backup                                         |" -ForegroundColor White
    Write-Host "  |      Bookmarks + Config + All project .idea directories      |" -ForegroundColor Gray
    Write-Host "  |      Size: ~570 MB  Speed: 1-2 minutes                       |" -ForegroundColor DarkGray
    Write-Host "  |                                                              |" -ForegroundColor White
    Write-Host "  |  [0] Exit                                                    |" -ForegroundColor White
    Write-Host "  |                                                              |" -ForegroundColor White
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""

    $choiceInput = Read-Host "  Enter choice (0-4)"
    $choice = if ($choiceInput) { $choiceInput.Trim() } else { "" }
    return $choice
}

# ============================================================
#  Helper: Map choice to mode
# ============================================================
function Get-ModeFromChoice {
    param([string]$Choice)
    switch ($Choice) {
        "1" { return "BookmarksOnly" }
        "2" { return "Lean" }
        "3" { return "Full" }
        "4" { return "All" }
        default { return $null }
    }
}

# ============================================================
#  Helper: Get mode description
# ============================================================
function Get-ModeDescription {
    param([string]$Mode)
    switch ($Mode) {
        "BookmarksOnly" { return "Bookmarks Only" }
        "Lean"          { return "Lean Backup (bookmarks + config, no plugins)" }
        "Full"          { return "Full Backup (bookmarks + config + plugins)" }
        "All"           { return "Complete Backup (bookmarks + config + plugins + project .idea)" }
        default         { return $Mode }
    }
}

# ============================================================
#  FUNCTION: Extract bookmarks from workspace XML
# ============================================================
function Extract-Bookmarks {
    param([string]$FilePath, [string]$OutputDir)

    if (-not (Test-Path $FilePath)) { return $false }

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $outFile = Join-Path $OutputDir "$fileName.bookmarks.xml"

    try {
        [xml]$doc = Get-Content $FilePath -Raw -Encoding UTF8
        $components = $doc.project.component
        $bookmarkComponent = $null
        foreach ($c in $components) {
            if ($c.name -eq "BookmarksManager") {
                $bookmarkComponent = $c
                break
            }
        }

        if ($bookmarkComponent) {
            $xmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<bookmarks-export source="$fileName" time="$Timestamp">
</bookmarks-export>
"@
            [xml]$newDoc = $xmlContent
            $imported = $newDoc.ImportNode($bookmarkComponent, $true)
            $newDoc.DocumentElement.AppendChild($imported) | Out-Null
            $newDoc.Save($outFile)

            # Count bookmarks
            $count = 0
            $groups = $bookmarkComponent.option | Where-Object { $_.name -eq "groups" }
            if ($groups -and $groups.GroupState) {
                foreach ($gs in $groups.GroupState) {
                    $bmOption = $gs.option | Where-Object { $_.name -eq "bookmarks" }
                    if ($bmOption -and $bmOption.BookmarkState) {
                        $count += @($bmOption.BookmarkState).Count
                    }
                }
            }

            Write-Host "    [OK] $fileName  ($count bookmarks)" -ForegroundColor Green
            return $true
        } else {
            return $false
        }
    }
    catch {
        Write-Host "    [WARN] $fileName - $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# ============================================================
#  FUNCTION: Run backup
# ============================================================
function Invoke-Backup {
    param([string]$BackupMode)

    $BackupDir = Join-Path $BackupRoot $Timestamp
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

    $modeDesc = Get-ModeDescription -Mode $BackupMode

    Write-Host ""
    Write-Host "  ==================================================================" -ForegroundColor Cyan
    Write-Host "   Mode:   $modeDesc" -ForegroundColor Cyan
    Write-Host "   Target: $BackupDir" -ForegroundColor Cyan
    Write-Host "  ==================================================================" -ForegroundColor Cyan
    Write-Host ""

    # ---- STEP 1: BOOKMARKS ----
    Write-Host "  [Step 1/3] Extracting bookmarks..." -ForegroundColor Yellow
    Write-Rule

    $bookmarksDir = Join-Path $BackupDir "bookmarks"
    New-Item -ItemType Directory -Path $bookmarksDir -Force | Out-Null

    $bookmarkFiles = 0
    if (Test-Path $WorkspaceDir) {
        foreach ($wsFile in (Get-ChildItem -Path $WorkspaceDir -Filter "*.xml")) {
            if (Extract-Bookmarks -FilePath $wsFile.FullName -OutputDir $bookmarksDir) {
                $bookmarkFiles++
            }
        }
    }

    Write-Host ""
    Write-Host "    => $bookmarkFiles project(s) contain bookmarks" -ForegroundColor Cyan

    if ($BackupMode -eq "BookmarksOnly") {
        Write-Host ""
        Write-Rule -Char "="
        Write-Host "    DONE! Bookmarks saved to:" -ForegroundColor Green
        Write-Host "    $bookmarksDir" -ForegroundColor White
        Write-Rule -Char "="
        return $BackupDir
    }

    # ---- STEP 2: CONFIG ----
    Write-Host ""
    Write-Host "  [Step 2/3] Backing up configuration..." -ForegroundColor Yellow
    Write-Rule

    $configBackupDir = Join-Path $BackupDir "config"

    if (Test-Path $RoamingDir) {
        $excludeDirs = @("caches", "index", "compile-server", "tmp", "log", "splash", "LocalHistory")
        if (-not $IncludePlugins -and $BackupMode -ne "Full") {
            $excludeDirs += "plugins"
            Write-Host "    (excluding plugins/ directory)" -ForegroundColor DarkGray
        }
        $robocopyArgs = @($RoamingDir, $configBackupDir, "/E", "/XF", "*.log", "*.tmp", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
        foreach ($d in $excludeDirs) { $robocopyArgs += "/XD"; $robocopyArgs += $d }

        & robocopy @robocopyArgs | Out-Null
        Write-Host "    [OK] Configuration backed up" -ForegroundColor Green
    } else {
        Write-Host "    [ERROR] Roaming directory not found: $RoamingDir" -ForegroundColor Red
    }

    if ($BackupMode -eq "Full" -or $BackupMode -eq "Lean") {
        Write-Host ""
        Write-Rule -Char "="
        Write-Host "    DONE! Backup saved to:" -ForegroundColor Green
        Write-Host "    $BackupDir" -ForegroundColor White
        Write-Rule -Char "="
        return $BackupDir
    }

    # ---- STEP 3: PROJECT .idea ----
    Write-Host ""
    Write-Host "  [Step 3/3] Backing up project .idea directories..." -ForegroundColor Yellow
    Write-Rule

    $projectDirs = Get-ChildItem -Path "D:\Code\WorkSpace" -Directory -Recurse -Filter ".idea" -Depth 2 -ErrorAction SilentlyContinue | ForEach-Object { $_.Parent.FullName }

    $projCount = 0
    foreach ($projDir in $projectDirs) {
        $ideaDir = Join-Path $projDir ".idea"
        if (Test-Path $ideaDir) {
            $projName = [System.IO.Path]::GetFileName($projDir)
            $projBackupDir = Join-Path $BackupDir "projects\$projName"
            New-Item -ItemType Directory -Path $projBackupDir -Force | Out-Null
            Copy-Item -Path $ideaDir -Destination $projBackupDir -Recurse -Force
            Write-Host "    [OK] $projName" -ForegroundColor Green
            $projCount++
        }
    }
    Write-Host "    => $projCount project(s) backed up" -ForegroundColor Cyan

    Write-Host ""
    Write-Rule -Char "="
    Write-Host "    ALL DONE! Backup saved to:" -ForegroundColor Green
    Write-Host "    $BackupDir" -ForegroundColor White
    Write-Rule -Char "="
    return $BackupDir
}

# ============================================================
#  Helper: Show backup summary
# ============================================================
function Show-BackupSummary {
    param([string]$BackupDir)

    if (-not (Test-Path $BackupDir)) { return }

    Write-Host ""
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Backup Summary:" -ForegroundColor White
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray

    # List contents
    $bookmarksDir = Join-Path $BackupDir "bookmarks"
    $configDir = Join-Path $BackupDir "config"
    $projectsDir = Join-Path $BackupDir "projects"

    if (Test-Path $bookmarksDir) {
        $bmCount = (Get-ChildItem -Path $bookmarksDir -Filter "*.bookmarks.xml" -ErrorAction SilentlyContinue).Count
        Write-Host "    bookmarks/  $bmCount bookmark file(s)" -ForegroundColor Gray
    }
    if (Test-Path $configDir) {
        Write-Host "    config/     IDEA global configuration" -ForegroundColor Gray
    }
    if (Test-Path $projectsDir) {
        $projCount = (Get-ChildItem -Path $projectsDir -Directory -ErrorAction SilentlyContinue).Count
        Write-Host "    projects/   $projCount project .idea director(ies)" -ForegroundColor Gray
    }

    # Total size
    $totalSize = (Get-ChildItem -Path $BackupDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($totalSize -ge 1MB) {
        Write-Host ""
        Write-Host "    Total size: $([math]::Round($totalSize/1MB, 2)) MB" -ForegroundColor Cyan
    } elseif ($totalSize -ge 1KB) {
        Write-Host ""
        Write-Host "    Total size: $([math]::Round($totalSize/1KB, 2)) KB" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "    Total size: $totalSize bytes" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Location: $BackupDir" -ForegroundColor White
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================
#  MAIN
# ============================================================

if ($Interactive) {
    # Interactive mode
    do {
        $choice = Show-Menu

        if ($choice -eq "0" -or $choice -eq "") {
            if ($choice -eq "0") {
                Write-Host ""
                Write-Host "  Exiting..." -ForegroundColor Gray
                Write-Host ""
            }
            break
        }

        $selectedMode = Get-ModeFromChoice -Choice $choice
        if ($null -eq $selectedMode) {
            Write-Host ""
            Write-Host "  [ERROR] Invalid choice: $choice" -ForegroundColor Red
            Write-Host "  Please enter 0-4." -ForegroundColor Yellow
            Write-Host ""
            Start-Sleep -Seconds 2
            continue
        }

        $result = Invoke-Backup -BackupMode $selectedMode
        if ($result) {
            Show-BackupSummary -BackupDir $result
        }

        Write-Host ""
        $againInput = Read-Host "  Run another backup? (y/N)"
        $again = if ($againInput) { $againInput.Trim() } else { "" }
        Write-Host ""
    } while ($again -eq "y" -or $again -eq "Y")

    exit 0
} else {
    # Direct mode
    $result = Invoke-Backup -BackupMode $Mode
    if ($result) {
        Show-BackupSummary -BackupDir $result
    }
    exit 0
}
