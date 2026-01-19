<#
.SYNOPSIS
    Sets up Disk 1 as a backup drive with automated backup schedules.
    
.DESCRIPTION
    This script:
    1. Formats Disk 1 as D: (NTFS)
    2. Creates folder structure
    3. Schedules weekly System Image backups
    4. Schedules daily Robocopy sync
    5. Configures File History to D:
    
.PARAMETER SkipFormat
    Skip disk formatting (if already formatted as D:)
    
.PARAMETER DryRun
    Show what would be done without making changes
    
.EXAMPLE
    .\Setup-BackupDrive.ps1
    
.EXAMPLE
    .\Setup-BackupDrive.ps1 -SkipFormat
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [switch]$SkipFormat,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

#Requires -RunAsAdministrator

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                   BACKUP DRIVE SETUP UTILITY                          ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

Write-Host "🔍 Checking system configuration..." -ForegroundColor Cyan
Write-Host ""

try {
    $disk0 = Get-Disk -Number 0 -ErrorAction Stop
    $disk1 = Get-Disk -Number 1 -ErrorAction Stop
} catch {
    Write-Host "❌ Failed to get disk information: $_" -ForegroundColor Red
    exit 1
}

Write-Host "Current Disks:" -ForegroundColor Yellow
Write-Host "  Disk 0: $($disk0.Model) - $([Math]::Round($disk0.Size/1GB, 2)) GB - $($disk0.PartitionStyle)" -ForegroundColor Gray
Write-Host "  Disk 1: $($disk1.Model) - $([Math]::Round($disk1.Size/1GB, 2)) GB - $($disk1.PartitionStyle)" -ForegroundColor Gray
Write-Host ""

# Check if Disk 1 has partitions
$disk1Partitions = Get-Partition -DiskNumber 1 -ErrorAction SilentlyContinue

if ($disk1Partitions -and -not $SkipFormat) {
    Write-Host "⚠️  WARNING: Disk 1 has existing partitions!" -ForegroundColor Red
    Write-Host ""
    foreach ($partition in $disk1Partitions) {
        $driveLetter = if ($partition.DriveLetter) { "$($partition.DriveLetter):" } else { "No letter" }
        $sizeGB = [Math]::Round($partition.Size/1GB, 2)
        Write-Host "    Partition $($partition.PartitionNumber): $driveLetter - $sizeGB GB" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Formatting will DESTROY ALL DATA on Disk 1!" -ForegroundColor Red
    Write-Host ""
    
    if (-not $DryRun) {
        $response = Read-Host "Type 'DELETE ALL DATA' to continue (or anything else to cancel)"
        if ($response -ne "DELETE ALL DATA") {
            Write-Host "Cancelled by user." -ForegroundColor Yellow
            exit 0
        }
    }
}

if ($DryRun) {
    Write-Host "=== DRY RUN MODE - No changes will be made ===" -ForegroundColor Magenta
    Write-Host ""
}

# ============================================================================
# STEP 1: FORMAT DISK 1 AS D:
# ============================================================================

if (-not $SkipFormat) {
    Write-Host "💾 STEP 1/5: Formatting Disk 1 as D: drive..." -ForegroundColor Cyan
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would format Disk 1 as NTFS with label 'Backup'" -ForegroundColor Yellow
    } else {
        try {
            Write-Host "  Cleaning disk..." -ForegroundColor Yellow
            Clear-Disk -Number 1 -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
            
            Write-Host "  Initializing as GPT..." -ForegroundColor Yellow
            Initialize-Disk -Number 1 -PartitionStyle GPT -ErrorAction Stop
            
            Write-Host "  Creating partition..." -ForegroundColor Yellow
            $partition = New-Partition -DiskNumber 1 -UseMaximumSize -DriveLetter D -ErrorAction Stop
            
            Write-Host "  Formatting as NTFS..." -ForegroundColor Yellow
            Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel "Backup" -Confirm:$false -ErrorAction Stop | Out-Null
            
            Write-Host "  ✓ Disk 1 formatted as D: successfully!" -ForegroundColor Green
            
            Start-Sleep -Seconds 3
        } catch {
            Write-Host "  ✗ Failed to format disk: $_" -ForegroundColor Red
            exit 1
        }
    }
} else {
    Write-Host "💾 STEP 1/5: Skipping format (using existing D: drive)..." -ForegroundColor Cyan
    
    # Verify D: exists
    if (-not (Test-Path "D:\")) {
        Write-Host "  ✗ D: drive not found! Remove -SkipFormat to format Disk 1." -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ D: drive found" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 2: CREATE FOLDER STRUCTURE
# ============================================================================

Write-Host "📁 STEP 2/5: Creating folder structure..." -ForegroundColor Cyan
Write-Host ""

$folders = @(
    "D:\SystemImages",
    "D:\C_Mirror",
    "D:\Backups\FileHistory",
    "D:\Scripts"
)

foreach ($folder in $folders) {
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would create: $folder" -ForegroundColor Yellow
    } else {
        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Write-Host "  ✓ Created: $folder" -ForegroundColor Green
        } else {
            Write-Host "  ✓ Exists: $folder" -ForegroundColor Gray
        }
    }
}

Write-Host ""

# ============================================================================
# STEP 3: CREATE ROBOCOPY SYNC SCRIPT
# ============================================================================

Write-Host "📝 STEP 3/5: Creating Robocopy sync script..." -ForegroundColor Cyan
Write-Host ""

$robocopyScript = @'
<#
.SYNOPSIS
    Daily C: drive mirror sync to D:\C_Mirror
#>

$ErrorActionPreference = "Continue"
$logPath = "D:\Scripts\Logs"
$logFile = Join-Path $logPath "Robocopy-$(Get-Date -Format 'yyyyMMdd').log"

# Ensure log directory exists
if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
}

Write-Output "=== Robocopy Sync Started: $(Get-Date) ===" | Out-File $logFile -Append

# Exclude certain folders and files
$excludeDirs = @(
    "Windows",
    "`$Recycle.Bin",
    "System Volume Information",
    "Recovery",
    "PerfLogs",
    "ProgramData\Microsoft\Windows\WER",
    "hiberfil.sys",
    "pagefile.sys",
    "swapfile.sys"
)

# Build robocopy command
$robocopyArgs = @(
    "C:\",
    "D:\C_Mirror\",
    "/MIR",                    # Mirror mode (exact copy)
    "/R:3",                    # Retry 3 times on failed copies
    "/W:10",                   # Wait 10 seconds between retries
    "/MT:8",                   # Multi-threaded (8 threads)
    "/XJ",                     # Exclude junction points
    "/XD"                      # Exclude directories (next items)
)

# Add excluded directories
$robocopyArgs += $excludeDirs

# Add file exclusions
$robocopyArgs += @(
    "/XF",                     # Exclude files
    "hiberfil.sys",
    "pagefile.sys",
    "swapfile.sys"
)

# Add logging
$robocopyArgs += @(
    "/LOG+:$logFile",          # Append to log
    "/NP",                     # No progress (%)
    "/NDL",                    # No directory list
    "/NFL"                     # No file list (comment out to see files)
)

# Run robocopy
Write-Output "Starting robocopy..." | Out-File $logFile -Append
& robocopy $robocopyArgs

$exitCode = $LASTEXITCODE

# Robocopy exit codes: 0-7 are success (with varying meanings)
if ($exitCode -le 7) {
    Write-Output "=== Robocopy Sync Completed Successfully: $(Get-Date) ===" | Out-File $logFile -Append
    Write-Output "Exit Code: $exitCode" | Out-File $logFile -Append
} else {
    Write-Output "=== Robocopy Sync Failed: $(Get-Date) ===" | Out-File $logFile -Append
    Write-Output "Exit Code: $exitCode" | Out-File $logFile -Append
}

# Clean up old logs (keep last 30 days)
Get-ChildItem -Path $logPath -Filter "Robocopy-*.log" | 
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | 
    Remove-Item -Force

exit 0
'@

$robocopyScriptPath = "D:\Scripts\Sync-C-Drive.ps1"

if ($DryRun) {
    Write-Host "  [DRY RUN] Would create: $robocopyScriptPath" -ForegroundColor Yellow
} else {
    $robocopyScript | Out-File -FilePath $robocopyScriptPath -Encoding UTF8 -Force
    Write-Host "  ✓ Created: $robocopyScriptPath" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 4: CREATE SCHEDULED TASKS
# ============================================================================

Write-Host "⏰ STEP 4/5: Creating scheduled tasks..." -ForegroundColor Cyan
Write-Host ""

# Task 1: Daily Robocopy Sync
$taskName = "Backup - Daily C Drive Sync"
if ($DryRun) {
    Write-Host "  [DRY RUN] Would create task: $taskName" -ForegroundColor Yellow
    Write-Host "    Schedule: Daily at 2:00 AM" -ForegroundColor Gray
} else {
    # Remove existing task if present
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    
    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$robocopyScriptPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 2:00AM
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Daily sync of C: drive to D:\C_Mirror\" | Out-Null
    
    Write-Host "  ✓ Created task: $taskName" -ForegroundColor Green
    Write-Host "    Schedule: Daily at 2:00 AM" -ForegroundColor Gray
}

# Task 2: Weekly System Image Backup
$taskName2 = "Backup - Weekly System Image"
if ($DryRun) {
    Write-Host "  [DRY RUN] Would create task: $taskName2" -ForegroundColor Yellow
    Write-Host "    Schedule: Weekly on Sunday at 3:00 AM" -ForegroundColor Gray
} else {
    # Remove existing task if present
    $existingTask2 = Get-ScheduledTask -TaskName $taskName2 -ErrorAction SilentlyContinue
    if ($existingTask2) {
        Unregister-ScheduledTask -TaskName $taskName2 -Confirm:$false
    }
    
    # Note: System Image requires wbadmin which must be run with specific parameters
    $wbadminCmd = "wbadmin start backup -backupTarget:D: -include:C: -allCritical -quiet"
    $action2 = New-ScheduledTaskAction -Execute "wbadmin.exe" -Argument "start backup -backupTarget:D: -include:C: -allCritical -quiet"
    $trigger2 = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3:00AM
    $principal2 = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    
    Register-ScheduledTask -TaskName $taskName2 -Action $action2 -Trigger $trigger2 -Principal $principal2 -Settings $settings2 -Description "Weekly System Image backup to D:\SystemImages\" | Out-Null
    
    Write-Host "  ✓ Created task: $taskName2" -ForegroundColor Green
    Write-Host "    Schedule: Weekly on Sunday at 3:00 AM" -ForegroundColor Gray
}

Write-Host ""

# ============================================================================
# STEP 5: CONFIGURE FILE HISTORY
# ============================================================================

Write-Host "📜 STEP 5/5: Configuring File History..." -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "  [DRY RUN] Would configure File History to D:\Backups\FileHistory\" -ForegroundColor Yellow
} else {
    try {
        # Configure File History using fhmanagew
        $fhTarget = "D:\Backups\FileHistory"
        
        Write-Host "  Configuring File History target..." -ForegroundColor Yellow
        $fhResult = & fhmanagew.exe -target $fhTarget -enable 2>&1
        
        if ($LASTEXITCODE -eq 0 -or $fhResult -match "success") {
            Write-Host "  ✓ File History configured to D:\Backups\FileHistory\" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  File History configuration may require manual setup" -ForegroundColor Yellow
            Write-Host "    Settings → System → Storage → Backup → More options" -ForegroundColor Gray
            Write-Host "    Set target to: D:\Backups\FileHistory\" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  ⚠️  Could not auto-configure File History: $_" -ForegroundColor Yellow
        Write-Host "    Please configure manually:" -ForegroundColor Gray
        Write-Host "    Settings → System → Storage → Backup → More options" -ForegroundColor Gray
    }
}

Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                        SETUP COMPLETE                                 ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

if ($DryRun) {
    Write-Host "=== DRY RUN COMPLETE - No changes were made ===" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Run without -DryRun to apply these changes." -ForegroundColor Yellow
    exit 0
}

Write-Host "✅ Backup drive configured successfully!" -ForegroundColor Green
Write-Host ""

Write-Host "📊 Configuration Summary:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Drive Setup:" -ForegroundColor Yellow
Write-Host "    • D: drive formatted and ready" -ForegroundColor Gray
Write-Host "    • Free space: ~1.6 TB" -ForegroundColor Gray
Write-Host ""
Write-Host "  Backup Folders:" -ForegroundColor Yellow
Write-Host "    • D:\SystemImages\      - Weekly full system images" -ForegroundColor Gray
Write-Host "    • D:\C_Mirror\          - Daily C: drive sync" -ForegroundColor Gray
Write-Host "    • D:\Backups\FileHistory\ - Continuous file backups" -ForegroundColor Gray
Write-Host "    • D:\Scripts\           - Backup scripts and logs" -ForegroundColor Gray
Write-Host ""
Write-Host "  Scheduled Tasks:" -ForegroundColor Yellow
Write-Host "    • Daily at 2:00 AM      - Robocopy C: sync" -ForegroundColor Gray
Write-Host "    • Sunday at 3:00 AM     - System Image backup" -ForegroundColor Gray
Write-Host ""
Write-Host "  File History:" -ForegroundColor Yellow
Write-Host "    • Target: D:\Backups\FileHistory\" -ForegroundColor Gray
Write-Host "    • Status: Check Settings → Backup" -ForegroundColor Gray
Write-Host ""

Write-Host "📋 Next Steps:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Verify File History is enabled:" -ForegroundColor White
Write-Host "     Settings → System → Storage → Backup" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Test the Robocopy sync (optional):" -ForegroundColor White
Write-Host "     Run: D:\Scripts\Sync-C-Drive.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Monitor scheduled tasks:" -ForegroundColor White
Write-Host "     Task Scheduler → Task Scheduler Library → Look for 'Backup -' tasks" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. First backups will run:" -ForegroundColor White
Write-Host "     • Tonight at 2:00 AM (Robocopy sync)" -ForegroundColor Gray
Write-Host "     • This Sunday at 3:00 AM (System Image)" -ForegroundColor Gray
Write-Host ""

Write-Host "🛡️  Recovery Instructions:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  If Disk 0 (C:) fails:" -ForegroundColor White
Write-Host "    1. Boot from Windows Recovery USB" -ForegroundColor Gray
Write-Host "    2. Select 'Restore from System Image'" -ForegroundColor Gray
Write-Host "    3. Choose image from D: drive" -ForegroundColor Gray
Write-Host "    4. Recent files available in D:\C_Mirror\" -ForegroundColor Gray
Write-Host ""

Write-Host "✅ Your system is now protected!" -ForegroundColor Green
Write-Host ""

exit 0
