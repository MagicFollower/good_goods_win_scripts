<#
.SYNOPSIS
    IDEA Configuration Restore Script
.DESCRIPTION
    Restores IntelliJ IDEA 2025.3 configuration and bookmarks from backup.
    Supports interactive menu mode (-Interactive) and direct mode.
.PARAMETER Interactive
    Launch interactive menu.
.PARAMETER BackupPath
    Path to the backup directory to restore from.
.PARAMETER Mode
    Restore mode: BookmarksOnly / Config / All
.PARAMETER SkipSafetyBackup
    Skip automatic safety backup of current config before restore.
.EXAMPLE
    .\Restore-IDEAConfig.ps1 -Interactive
    .\Restore-IDEAConfig.ps1 -BackupPath "D:\Code\WorkSpace\.qoder\idea-backups\20261029_084149" -Mode BookmarksOnly
#>
param(
    [switch]$Interactive,
    [string]$BackupPath = "",
    [ValidateSet("BookmarksOnly", "Config", "All")]
    [string]$Mode = "Config",
    [switch]$SkipSafetyBackup
)

$ErrorActionPreference = "Stop"

# ============================================================
#  Constants
# ============================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$IdeaVersion = "IntelliJIdea2025.3"
$RoamingDir = Join-Path $env:APPDATA "JetBrains\$IdeaVersion"
$WorkspaceDir = Join-Path $RoamingDir "workspace"
$BackupRoot = "D:\Code\WorkSpace\.qoder\idea-backups"

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
    Write-Host "  |          IntelliJ IDEA  Configuration Restore Tool             |" -ForegroundColor Cyan
    Write-Host "  |                    2025.3  |  Windows                         |" -ForegroundColor Cyan
    Write-Host "  |                                                                |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
#  Helper: List available backups
# ============================================================
function Get-AvailableBackups {
    if (-not (Test-Path $BackupRoot)) {
        return @()
    }
    $backups = Get-ChildItem -Path $BackupRoot -Directory | Sort-Object Name -Descending
    return $backups
}

# ============================================================
#  Helper: Show backup selection menu
# ============================================================
function Select-Backup {
    $backups = Get-AvailableBackups
    if ($backups.Count -eq 0) {
        Write-Host "  [ERROR] No backups found in: $BackupRoot" -ForegroundColor Red
        return $null
    }

    Write-Host "  Available backups:" -ForegroundColor Yellow
    Write-Rule
    Write-Host ""

    for ($i = 0; $i -lt $backups.Count; $i++) {
        $b = $backups[$i]
        $size = (Get-ChildItem -Path $b.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $sizeStr = if ($size -ge 1MB) { "$([math]::Round($size/1MB, 2)) MB" } elseif ($size -ge 1KB) { "$([math]::Round($size/1KB, 2)) KB" } else { "$size bytes" }

        $contents = @()
        if (Test-Path (Join-Path $b.FullName "bookmarks")) { $contents += "bookmarks" }
        if (Test-Path (Join-Path $b.FullName "config")) { $contents += "config" }
        if (Test-Path (Join-Path $b.FullName "projects")) { $contents += "projects" }

        Write-Host "    [$($i+1)] $($b.Name)  ($sizeStr)  [$($contents -join ', ')]" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "    [0] Cancel" -ForegroundColor Gray
    Write-Host ""

    $choiceInput = Read-Host "  Select backup to restore (0-$($backups.Count))"
    $choice = if ($choiceInput) { $choiceInput.Trim() } else { "" }

    if ($choice -eq "0" -or $choice -eq "") { return $null }

    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx)) {
        if ($idx -ge 1 -and $idx -le $backups.Count) {
            return $backups[$idx - 1]
        }
    }

    Write-Host "  [ERROR] Invalid selection: $choice" -ForegroundColor Red
    return $null
}

# ============================================================
#  Helper: Show restore mode menu
# ============================================================
function Select-RestoreMode {
    Write-Host ""
    Write-Host "  Restore mode:" -ForegroundColor Yellow
    Write-Rule
    Write-Host ""
    Write-Host "    [1] Bookmarks Only   - Restore bookmarks to workspace XML files" -ForegroundColor White
    Write-Host "    [2] Config           - Restore IDEA global config (options, keymaps, etc.)" -ForegroundColor White
    Write-Host "    [3] All              - Restore everything (config + bookmarks + project .idea)" -ForegroundColor White
    Write-Host "    [0] Cancel" -ForegroundColor Gray
    Write-Host ""

    $choiceInput = Read-Host "  Select restore mode (0-3)"
    $choice = if ($choiceInput) { $choiceInput.Trim() } else { "" }

    switch ($choice) {
        "1" { return "BookmarksOnly" }
        "2" { return "Config" }
        "3" { return "All" }
        default { return $null }
    }
}

# ============================================================
#  Safety: Backup current config before restore
# ============================================================
function Invoke-SafetyBackup {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safetyDir = Join-Path $BackupRoot "safety_backup_$timestamp"

    Write-Host ""
    Write-Host "  [Safety] Creating safety backup of current config..." -ForegroundColor Yellow

    if (Test-Path $RoamingDir) {
        $excludeDirs = @("caches", "index", "compile-server", "tmp", "log", "splash", "LocalHistory", "plugins")
        $robocopyArgs = @($RoamingDir, (Join-Path $safetyDir "config"), "/E", "/XF", "*.log", "*.tmp", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
        foreach ($d in $excludeDirs) { $robocopyArgs += "/XD"; $robocopyArgs += $d }
        & robocopy @robocopyArgs | Out-Null
        Write-Host "    [OK] Safety backup saved to: $safetyDir" -ForegroundColor Green
        return $safetyDir
    }

    return $null
}

# ============================================================
#  FUNCTION: Restore bookmarks
# ============================================================
function Restore-Bookmarks {
    param([string]$BookmarksBackupDir)

    if (-not (Test-Path $BookmarksBackupDir)) {
        Write-Host "    [ERROR] Bookmarks backup directory not found" -ForegroundColor Red
        return $false
    }

    $bookmarkFiles = Get-ChildItem -Path $BookmarksBackupDir -Filter "*.bookmarks.xml" -ErrorAction SilentlyContinue
    if (-not $bookmarkFiles) {
        Write-Host "    [WARN] No bookmark files found in backup" -ForegroundColor Yellow
        return $false
    }

    Write-Host "    Found $($bookmarkFiles.Count) bookmark file(s) to restore" -ForegroundColor Cyan

    $restored = 0
    foreach ($bmFile in $bookmarkFiles) {
        # Extract hash from filename: <hash>.bookmarks.xml -> <hash>
        $hash = $bmFile.BaseName -replace '\.bookmarks$', ''
        $targetWsFile = Join-Path $WorkspaceDir "$hash.xml"

        if (-not (Test-Path $targetWsFile)) {
            Write-Host "    [SKIP] $hash - workspace file not found (project may have been removed)" -ForegroundColor Yellow
            continue
        }

        try {
            # Read backup bookmarks
            [xml]$bmDoc = Get-Content $bmFile.FullName -Raw -Encoding UTF8
            $bmComponent = $bmDoc.'bookmarks-export'.component

            if (-not $bmComponent) {
                Write-Host "    [SKIP] $hash - no BookmarksManager component in backup" -ForegroundColor Yellow
                continue
            }

            # Read target workspace file
            [xml]$wsDoc = Get-Content $targetWsFile -Raw -Encoding UTF8

            # Check if BookmarksManager already exists
            $existingComponent = $null
            foreach ($c in $wsDoc.project.component) {
                if ($c.name -eq "BookmarksManager") {
                    $existingComponent = $c
                    break
                }
            }

            if ($existingComponent) {
                # Replace existing component
                $imported = $wsDoc.ImportNode($bmComponent, $true)
                $wsDoc.project.ReplaceChild($imported, $existingComponent) | Out-Null
            } else {
                # Add new component
                $imported = $wsDoc.ImportNode($bmComponent, $true)
                $wsDoc.project.AppendChild($imported) | Out-Null
            }

            # Save
            $wsDoc.Save($targetWsFile)
            Write-Host "    [OK] $hash - bookmarks restored" -ForegroundColor Green
            $restored++
        }
        catch {
            Write-Host "    [ERROR] $hash - $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "    => $restored/$($bookmarkFiles.Count) bookmark file(s) restored" -ForegroundColor Cyan
    return $restored -gt 0
}

# ============================================================
#  FUNCTION: Restore config
# ============================================================
function Restore-Config {
    param([string]$ConfigBackupDir)

    if (-not (Test-Path $ConfigBackupDir)) {
        Write-Host "    [ERROR] Config backup directory not found" -ForegroundColor Red
        return $false
    }

    Write-Host "    Restoring configuration to: $RoamingDir" -ForegroundColor Cyan

    try {
        # Use robocopy to restore
        $robocopyArgs = @($ConfigBackupDir, $RoamingDir, "/E", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
        & robocopy @robocopyArgs | Out-Null
        Write-Host "    [OK] Configuration restored" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "    [ERROR] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ============================================================
#  FUNCTION: Restore project .idea directories
# ============================================================
function Restore-Projects {
    param([string]$ProjectsBackupDir)

    if (-not (Test-Path $ProjectsBackupDir)) {
        Write-Host "    [WARN] No project backups found" -ForegroundColor Yellow
        return $false
    }

    $projectDirs = Get-ChildItem -Path $ProjectsBackupDir -Directory -ErrorAction SilentlyContinue
    if (-not $projectDirs) {
        Write-Host "    [WARN] No project directories in backup" -ForegroundColor Yellow
        return $false
    }

    $restored = 0
    foreach ($projDir in $projectDirs) {
        $projName = $projDir.Name
        $targetIdeaDir = Join-Path "D:\Code\WorkSpace" "$projName\.idea"

        if (-not (Test-Path (Split-Path $targetIdeaDir -Parent))) {
            Write-Host "    [SKIP] $projName - project directory not found" -ForegroundColor Yellow
            continue
        }

        try {
            if (Test-Path $targetIdeaDir) {
                # Backup existing .idea
                $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                $backupPath = "$targetIdeaDir.before_restore_$timestamp"
                Rename-Item -Path $targetIdeaDir -NewName "idea_backup_$timestamp" -Force
            }

            Copy-Item -Path $projDir.FullName -Destination $targetIdeaDir -Recurse -Force
            Write-Host "    [OK] $projName" -ForegroundColor Green
            $restored++
        }
        catch {
            Write-Host "    [ERROR] $projName - $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host "    => $restored/$($projectDirs.Count) project(s) restored" -ForegroundColor Cyan
    return $restored -gt 0
}

# ============================================================
#  FUNCTION: Run restore
# ============================================================
function Invoke-Restore {
    param(
        [string]$SelectedBackupPath,
        [string]$RestoreMode
    )

    Write-Host ""
    Write-Host "  ==================================================================" -ForegroundColor Cyan
    Write-Host "   Restoring from: $SelectedBackupPath" -ForegroundColor Cyan
    Write-Host "   Mode: $RestoreMode" -ForegroundColor Cyan
    Write-Host "  ==================================================================" -ForegroundColor Cyan
    Write-Host ""

    # Safety backup
    if (-not $SkipSafetyBackup) {
        $safetyDir = Invoke-SafetyBackup
        if ($safetyDir) {
            Write-Host "    You can rollback to: $safetyDir" -ForegroundColor DarkGray
        }
    }

    $success = $false

    # Restore based on mode
    if ($RestoreMode -eq "BookmarksOnly" -or $RestoreMode -eq "Config" -or $RestoreMode -eq "All") {
        $bookmarksDir = Join-Path $SelectedBackupPath "bookmarks"
        if (Test-Path $bookmarksDir) {
            Write-Host ""
            Write-Host "  [Step 1/3] Restoring bookmarks..." -ForegroundColor Yellow
            Write-Rule
            Restore-Bookmarks -BookmarksBackupDir $bookmarksDir
        }
    }

    if ($RestoreMode -eq "Config" -or $RestoreMode -eq "All") {
        $configDir = Join-Path $SelectedBackupPath "config"
        if (Test-Path $configDir) {
            Write-Host ""
            Write-Host "  [Step 2/3] Restoring configuration..." -ForegroundColor Yellow
            Write-Rule
            Restore-Config -ConfigBackupDir $configDir
        }
    }

    if ($RestoreMode -eq "All") {
        $projectsDir = Join-Path $SelectedBackupPath "projects"
        if (Test-Path $projectsDir) {
            Write-Host ""
            Write-Host "  [Step 3/3] Restoring project .idea directories..." -ForegroundColor Yellow
            Write-Rule
            Restore-Projects -ProjectsBackupDir $projectsDir
        }
    }

    Write-Host ""
    Write-Rule -Char "="
    Write-Host "    RESTORE COMPLETE!" -ForegroundColor Green
    Write-Host ""
    Write-Host "    IMPORTANT: Please restart IntelliJ IDEA to apply changes." -ForegroundColor Yellow
    Write-Rule -Char "="
    Write-Host ""
}

# ============================================================
#  MAIN
# ============================================================

if ($Interactive) {
    # Interactive mode
    Write-Banner

    # Select backup
    $selectedBackup = Select-Backup
    if (-not $selectedBackup) {
        Write-Host ""
        Write-Host "  Cancelled." -ForegroundColor Gray
        exit 0
    }

    # Select restore mode
    $restoreMode = Select-RestoreMode
    if (-not $restoreMode) {
        Write-Host ""
        Write-Host "  Cancelled." -ForegroundColor Gray
        exit 0
    }

    # Confirm
    Write-Host ""
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  Confirm restore:" -ForegroundColor Yellow
    Write-Host "    Backup: $($selectedBackup.FullName)" -ForegroundColor White
    Write-Host "    Mode:   $restoreMode" -ForegroundColor White
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
    $confirmInput = Read-Host "  Proceed? (y/N)"
    $confirm = if ($confirmInput) { $confirmInput.Trim() } else { "" }

    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host ""
        Write-Host "  Cancelled." -ForegroundColor Gray
        exit 0
    }

    Invoke-Restore -SelectedBackupPath $selectedBackup.FullName -RestoreMode $restoreMode
    exit 0
} else {
    # Direct mode
    if (-not $BackupPath) {
        Write-Host "[ERROR] -BackupPath is required in direct mode" -ForegroundColor Red
        exit 1
    }

    if (-not (Test-Path $BackupPath)) {
        Write-Host "[ERROR] Backup path not found: $BackupPath" -ForegroundColor Red
        exit 1
    }

    Invoke-Restore -SelectedBackupPath $BackupPath -RestoreMode $Mode
    exit 0
}
