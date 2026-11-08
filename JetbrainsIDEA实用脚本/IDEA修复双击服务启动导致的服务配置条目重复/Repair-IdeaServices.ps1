<#
.SYNOPSIS
    Repair IntelliJ IDEA Services (Run Dashboard) panel issues for this multi-Maven workspace.

.DESCRIPTION
    Fixes the combined "duplicate + missing entries" problem:
      1. modules.xml        - removes dumb (manually attached) modules and their .iml files,
                              and removes dangling module registrations. Every deleted .iml
                              is copied into the backup folder first, and the root project
                              module stored inside .idea is never touched.
      2. workspace.xml      - clears RunDashboard.hiddenConfigurations
                              (panel "Delete" hides entries; this makes them visible again)
      3. workspace.xml      - removes auto-generated Spring Boot run configurations
                              (configuration[@nameIsGenerated='true']) which cause duplicates.
                              Only applied when an anomaly is found: dumb/dangling module,
                              hidden entries, or duplicate run configurations.
                              Stale RunManager <list> items and a 'selected' attribute that
                              points to a removed config are cleaned up as well.
      4. workspace.xml      - ensures SpringBootApplicationConfigurationType is listed in
                              RunDashboard.configurationTypes
    Every modified file is backed up first. Idempotent: safe to run repeatedly.
    Does NOT touch external_build_system caches (Maven module models stay intact).

.PARAMETER Workspace
    Workspace root containing the .idea directory. Default: D:\Code\XXXXX

.PARAMETER DryRun
    Show what would be changed without modifying any file.

.PARAMETER SkipProcessCheck
    Skip the idea64.exe running check (for testing on temp copies).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Repair-IdeaServices.ps1 -DryRun
#>
param(
    [string]$Workspace = "D:\Code\XXXXX",
    [switch]$DryRun,
    [switch]$SkipProcessCheck
)

$ErrorActionPreference = 'Stop'

function Write-Ok([string]$msg)   { Write-Host ("    -> " + $msg) }
function Write-Skip([string]$msg) { Write-Host ("    -> SKIP: " + $msg) }

# ---------- 0. preflight ----------
if (-not $SkipProcessCheck) {
    $proc = Get-Process -Name idea64 -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "[ABORT] IntelliJ IDEA (idea64.exe) is still running." -ForegroundColor Yellow
        Write-Host "        Close ALL IDEA windows first, then run this script again."
        Write-Host "        (Reason: a running IDEA would overwrite these file fixes from memory.)"
        exit 1
    }
}

$ideaDir    = Join-Path $Workspace '.idea'
$wsXml      = Join-Path $ideaDir 'workspace.xml'
$modulesXml = Join-Path $ideaDir 'modules.xml'
foreach ($f in @($wsXml, $modulesXml)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host ("[ABORT] File not found: " + $f) -ForegroundColor Red
        exit 1
    }
}

function Load-Xml([string]$path) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($path)
    return $doc
}

# ---------- 1. backup ----------
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$bakDir = Join-Path $ideaDir ('repair_backup_' + $stamp)
if ($DryRun) {
    Write-Host "[*] DryRun: backup would be created at " $bakDir
} else {
    New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
    Copy-Item -LiteralPath $wsXml      -Destination $bakDir -Force
    Copy-Item -LiteralPath $modulesXml -Destination $bakDir -Force
    Write-Host ("[*] Backup created: " + $bakDir)
}

$changes = New-Object System.Collections.Generic.List[string]
$foundDumbOrDangling = $false
$foundHidden = $false

# ---------- 2. modules.xml: dumb / dangling module registrations ----------
Write-Host "[*] Checking modules.xml for dumb or dangling module registrations..."
$mDoc = Load-Xml $modulesXml
$mModified = $false
foreach ($mod in @($mDoc.SelectNodes('//module'))) {
    $url = $mod.GetAttribute('fileurl')
    if (-not $url) { continue }
    $path = $url.Replace('$PROJECT_DIR$', $Workspace)
    $path = $path -replace '^file:///', ''
    $path = $path -replace '^file://', ''
    $path = [System.Uri]::UnescapeDataString($path)
    $path = ($path -replace '/', '\')
    if (Test-Path -LiteralPath $path) {
        # never touch the root project module stored inside .idea
        if ($path.StartsWith($ideaDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Skip ("root project module kept (inside .idea): " + $path)
            continue
        }
        $content = Get-Content -LiteralPath $path -Raw
        if ($content -match 'dumb\s*=\s*"true"') {
            $foundDumbOrDangling = $true
            $changes.Add("removed dumb module: $path")
            if ($DryRun) {
                Write-Ok ("DryRun: would back up and delete dumb module file and its registration: " + $path)
            } else {
                Copy-Item -LiteralPath $path -Destination (Join-Path $bakDir ([System.IO.Path]::GetFileName($path))) -Force
                Remove-Item -LiteralPath $path -Force
                [void]$mod.ParentNode.RemoveChild($mod)
                $mModified = $true
                Write-Ok ("Deleted dumb module: " + $path)
            }
        }
    } else {
        $foundDumbOrDangling = $true
        $changes.Add("removed dangling module ref: $path")
        if ($DryRun) {
            Write-Ok ("DryRun: would remove dangling registration: " + $path)
        } else {
            [void]$mod.ParentNode.RemoveChild($mod)
            $mModified = $true
            Write-Ok ("Removed dangling registration: " + $path)
        }
    }
}
if ($mModified -and -not $DryRun) {
    $mDoc.Save($modulesXml)
    Write-Ok "modules.xml saved."
}

# ---------- 3. workspace.xml ----------
Write-Host "[*] Checking workspace.xml (hidden entries / generated run configs / service types)..."
$wDoc = Load-Xml $wsXml
$wModified = $false

# 3a. hiddenConfigurations - entries the user "deleted" in the Services panel
$hidden = $wDoc.SelectSingleNode("/project/component[@name='RunDashboard']/option[@name='hiddenConfigurations']")
if ($hidden) {
    $foundHidden = $true
    $changes.Add("cleared RunDashboard.hiddenConfigurations")
    if ($DryRun) {
        Write-Ok "DryRun: would clear RunDashboard.hiddenConfigurations (hidden services will show again)"
    } else {
        [void]$hidden.ParentNode.RemoveChild($hidden)
        $wModified = $true
        Write-Ok "Cleared RunDashboard.hiddenConfigurations (previously hidden services will show again)."
    }
} else {
    Write-Skip "no hiddenConfigurations (already clean)"
}

# 3b. ensure Spring Boot is listed as a service type
$typesSet = $wDoc.SelectSingleNode("/project/component[@name='RunDashboard']/option[@name='configurationTypes']/set")
if ($typesSet) {
    $exists = $typesSet.SelectNodes("option[@value='SpringBootApplicationConfigurationType']").Count -gt 0
    if ($exists) {
        Write-Skip "Spring Boot already listed in Services types"
    } else {
        $changes.Add("added Spring Boot service type")
        if ($DryRun) {
            Write-Ok "DryRun: would add SpringBootApplicationConfigurationType to Services types"
        } else {
            $opt = $wDoc.CreateElement('option')
            [void]$opt.SetAttribute('value', 'SpringBootApplicationConfigurationType')
            [void]$typesSet.AppendChild($opt)
            $wModified = $true
            Write-Ok "Added SpringBootApplicationConfigurationType to Services types."
        }
    }
} else {
    Write-Skip "RunDashboard.configurationTypes not present (IDEA will manage it)"
}

# 3c. remove auto-generated Spring Boot run configurations (duplicate source)
$runMgr = $wDoc.SelectSingleNode("/project/component[@name='RunManager']")
if ($runMgr) {
    # anomaly gate: only wipe generated configs when something is actually wrong
    $bootCfgs = @($runMgr.SelectNodes("configuration[@type='SpringBootApplicationConfigurationType']"))
    $seen = @{}
    $dupPairs = 0
    foreach ($c in $bootCfgs) {
        # the module is a child element, not an attribute: <module name="..." />
        $modName = ''
        $mn = $c.SelectSingleNode('module')
        if ($mn) { $modName = $mn.GetAttribute('name') }
        $k = $c.GetAttribute('name') + '::' + $modName
        if ($seen.ContainsKey($k)) { $dupPairs++ } else { $seen[$k] = $true }
    }
    if ($dupPairs -gt 0) {
        Write-Host ("    !! duplicate run configuration pair(s) detected: " + $dupPairs) -ForegroundColor Yellow
    }

    $gen = @($runMgr.SelectNodes("configuration[@type='SpringBootApplicationConfigurationType' and @nameIsGenerated='true']"))
    if ($gen.Count -eq 0) {
        Write-Skip "no nameIsGenerated Spring Boot run configurations"
        if ($dupPairs -gt 0) {
            Write-Host "    !! duplicates involve manually named configs - remove them in the IDE." -ForegroundColor Yellow
        }
    } elseif (-not ($foundDumbOrDangling -or $foundHidden -or $dupPairs -gt 0)) {
        Write-Skip "run configs look normal (no dumb module / hidden entries / duplicates) - generated configs kept"
    } else {
        $removedNames = New-Object System.Collections.Generic.List[string]
        foreach ($c in $gen) {
            $removedNames.Add($c.GetAttribute('name'))
            $changes.Add(("removed generated run config: " + $c.GetAttribute('name')))
            if ($DryRun) {
                Write-Ok ("DryRun: would remove generated run config: " + $c.GetAttribute('name'))
            } else {
                [void]$runMgr.RemoveChild($c)
                Write-Ok ("Removed generated run config: " + $c.GetAttribute('name'))
            }
        }
        if (-not $DryRun) { $wModified = $true }

        # stale <list> items that still point to removed configs
        $dashList = $runMgr.SelectSingleNode('list')
        if ($dashList) {
            foreach ($item in @($dashList.SelectNodes('item'))) {
                $iv = $item.GetAttribute('itemvalue')
                $plain = $iv -replace '^Spring Boot\.', '' -replace '^SpringBootApplicationConfigurationType\.', ''
                if ($removedNames -contains $plain) {
                    $changes.Add(("removed stale list item: " + $iv))
                    if ($DryRun) {
                        Write-Ok ("DryRun: would remove stale RunManager list item: " + $iv)
                    } else {
                        [void]$dashList.RemoveChild($item)
                        Write-Ok ("Removed stale RunManager list item: " + $iv)
                    }
                }
            }
        }

        # 'selected' attribute may point to a just-removed config -> clear it
        $sel = $runMgr.GetAttribute('selected')
        if ($sel) {
            $selName = $sel -replace '^Spring Boot\.', '' -replace '^SpringBootApplicationConfigurationType\.', ''
            if ($removedNames -contains $selName) {
                if ($DryRun) {
                    Write-Ok "DryRun: would clear stale RunManager 'selected' attribute"
                } else {
                    [void]$runMgr.RemoveAttribute('selected')
                    Write-Ok "Cleared stale RunManager 'selected' attribute."
                }
            }
        }
    }
} else {
    Write-Skip "no RunManager component"
}

if ($wModified -and -not $DryRun) {
    $wDoc.Save($wsXml)
    Write-Ok "workspace.xml saved."
}

# ---------- 4. summary ----------
Write-Host ""
if ($DryRun) {
    Write-Host ("[DRYRUN] " + $changes.Count + " change(s) planned. No files were modified. Run again without -DryRun to apply.") -ForegroundColor Cyan
} elseif ($changes.Count -eq 0) {
    Write-Host "[DONE] Nothing to repair - project config is already clean." -ForegroundColor Green
} else {
    Write-Host ("[DONE] Applied " + $changes.Count + " fix(es).") -ForegroundColor Green
}
Write-Host "Next: start IDEA, wait for Maven import to finish, then check the Services panel."
if (-not $DryRun -and (Test-Path -LiteralPath $bakDir)) {
    Write-Host ("Rollback if needed: restore the files in " + $bakDir + " to their original locations (it also holds any deleted .iml).")
}
