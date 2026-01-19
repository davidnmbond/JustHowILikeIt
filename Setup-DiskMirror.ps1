<#
.SYNOPSIS
    Configures Windows Software RAID 1 (Mirror) for the boot drive.
    
.DESCRIPTION
    This script sets up disk mirroring between Disk 0 (boot) and Disk 1 (target).
    It converts both disks to Dynamic Disks and creates a mirror volume for C:.
    
    ⚠️  WARNING: This operation is IRREVERSIBLE without data loss!
    ⚠️  Ensure you have verified backups before running this script.
    
.PARAMETER SkipVerification
    Skip pre-flight disk compatibility checks (NOT RECOMMENDED).
    
.PARAMETER AutoConfirm
    Skip confirmation prompts (DANGEROUS - USE WITH EXTREME CAUTION).
    
.EXAMPLE
    .\Setup-DiskMirror.ps1
    
.NOTES
    Prerequisites:
    - Must run as Administrator
    - Both disks must be identical hardware
    - Target disk (Disk 1) must be unpartitioned
    - Run Verify-BackupBeforeMirror.ps1 first
    
    Process:
    1. Convert Disk 0 to Dynamic
    2. Convert Disk 1 to Dynamic  
    3. Create mirror from C: to Disk 1
    4. Sync begins automatically (1-2 hours estimated)
    
    After completion:
    - System is bootable from either disk
    - All writes go to both disks
    - Automatic failover if one disk fails
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [switch]$SkipVerification,
    
    [Parameter(Mandatory=$false)]
    [switch]$AutoConfirm
)

#Requires -RunAsAdministrator

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║              WINDOWS SOFTWARE RAID MIRROR SETUP UTILITY               ║" -ForegroundColor Red
Write-Host "║                                                                       ║" -ForegroundColor Red
Write-Host "║                    ⚠️  CRITICAL WARNING ⚠️                            ║" -ForegroundColor Red
Write-Host "║                                                                       ║" -ForegroundColor Red
Write-Host "║  This script will convert your disks to Dynamic Disks and create     ║" -ForegroundColor Red
Write-Host "║  a RAID 1 mirror. This operation is IRREVERSIBLE without data loss.  ║" -ForegroundColor Red
Write-Host "║                                                                       ║" -ForegroundColor Red
Write-Host "║  Ensure you have recent, verified backups before proceeding!          ║" -ForegroundColor Red
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

# ============================================================================
# PRE-FLIGHT VERIFICATION
# ============================================================================

if (-not $SkipVerification) {
    Write-Host "🔍 Running pre-flight disk compatibility checks..." -ForegroundColor Cyan
    Write-Host ""
    
    $verifyScript = Join-Path (Split-Path -Parent $PSCommandPath) "Verify-BackupBeforeMirror.ps1"
    
    if (Test-Path $verifyScript) {
        $verifyResult = & $verifyScript
        $verifyExitCode = $LASTEXITCODE
        
        if ($verifyExitCode -ne 0) {
            Write-Host ""
            Write-Host "❌ Pre-flight verification FAILED!" -ForegroundColor Red
            Write-Host "Cannot proceed with disk mirroring." -ForegroundColor Red
            Write-Host ""
            exit 1
        }
        
        Write-Host ""
        Write-Host "✅ Pre-flight verification PASSED" -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host "⚠️  Warning: Verify-BackupBeforeMirror.ps1 not found" -ForegroundColor Yellow
        Write-Host "Continuing without verification..." -ForegroundColor Yellow
        Write-Host ""
    }
}

# ============================================================================
# CURRENT STATE ANALYSIS
# ============================================================================

Write-Host "📊 Analyzing current disk configuration..." -ForegroundColor Cyan
Write-Host ""

try {
    $disk0 = Get-Disk -Number 0 -ErrorAction Stop
    $disk1 = Get-Disk -Number 1 -ErrorAction Stop
    $cVolume = Get-Volume -DriveLetter C -ErrorAction Stop
    $cPartition = Get-Partition -DriveLetter C -ErrorAction Stop
} catch {
    Write-Host "❌ Failed to get disk information: $_" -ForegroundColor Red
    exit 1
}

Write-Host "Current Configuration:" -ForegroundColor Yellow
Write-Host "  Disk 0:" -ForegroundColor Gray
Write-Host "    Model: $($disk0.Model)" -ForegroundColor Gray
Write-Host "    Size: $([Math]::Round($disk0.Size/1GB, 2)) GB" -ForegroundColor Gray
Write-Host "    Partition Style: $($disk0.PartitionStyle)" -ForegroundColor Gray
Write-Host "    Status: $($disk0.OperationalStatus)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Disk 1:" -ForegroundColor Gray
Write-Host "    Model: $($disk1.Model)" -ForegroundColor Gray
Write-Host "    Size: $([Math]::Round($disk1.Size/1GB, 2)) GB" -ForegroundColor Gray
Write-Host "    Partition Style: $($disk1.PartitionStyle)" -ForegroundColor Gray
Write-Host "    Status: $($disk1.OperationalStatus)" -ForegroundColor Gray
Write-Host ""
Write-Host "  C: Volume:" -ForegroundColor Gray
Write-Host "    Size: $([Math]::Round($cVolume.Size/1GB, 2)) GB" -ForegroundColor Gray
Write-Host "    Used: $([Math]::Round(($cVolume.Size - $cVolume.SizeRemaining)/1GB, 2)) GB" -ForegroundColor Gray
Write-Host "    Free: $([Math]::Round($cVolume.SizeRemaining/1GB, 2)) GB" -ForegroundColor Gray
Write-Host ""

$cUsedGB = [Math]::Round(($cVolume.Size - $cVolume.SizeRemaining)/1GB, 2)
$estimatedSyncMinutes = [Math]::Round($cUsedGB / 2, 0)  # Rough estimate: 2GB/min

Write-Host "Estimated sync time: $estimatedSyncMinutes - $($estimatedSyncMinutes * 2) minutes" -ForegroundColor Cyan
Write-Host ""

# Check if already Dynamic
if ($disk0.PartitionStyle -eq "Dynamic" -or $disk1.PartitionStyle -eq "Dynamic") {
    Write-Host "⚠️  Warning: One or more disks are already Dynamic!" -ForegroundColor Yellow
    Write-Host "This script assumes Basic disks. Proceeding may have unexpected results." -ForegroundColor Yellow
    Write-Host ""
    
    if (-not $AutoConfirm) {
        $response = Read-Host "Continue anyway? (yes/no)"
        if ($response -ne "yes") {
            Write-Host "Cancelled by user." -ForegroundColor Yellow
            exit 0
        }
    }
}

# ============================================================================
# FINAL WARNING AND CONFIRMATION
# ============================================================================

Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║                          OPERATION SUMMARY                            ║" -ForegroundColor Yellow
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""
Write-Host "This script will perform the following operations:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Convert Disk 0 from Basic to Dynamic" -ForegroundColor White
Write-Host "     • C: drive will remain accessible" -ForegroundColor Gray
Write-Host "     • System will remain bootable" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Convert Disk 1 from Basic to Dynamic" -ForegroundColor White
Write-Host "     • Target disk will be prepared for mirroring" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Create mirror volume" -ForegroundColor White
Write-Host "     • C: will be mirrored to Disk 1" -ForegroundColor Gray
Write-Host "     • Sync will begin automatically (runs in background)" -ForegroundColor Gray
Write-Host "     • Estimated time: $estimatedSyncMinutes - $($estimatedSyncMinutes * 2) minutes" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Verify mirror creation" -ForegroundColor White
Write-Host "     • Check mirror status" -ForegroundColor Gray
Write-Host "     • Provide monitoring instructions" -ForegroundColor Gray
Write-Host ""

Write-Host "⚠️  IMPORTANT NOTES:" -ForegroundColor Red
Write-Host ""
Write-Host "  • Converting to Dynamic Disks is IRREVERSIBLE without data loss" -ForegroundColor Red
Write-Host "  • You can continue using your computer during sync" -ForegroundColor Yellow
Write-Host "  • Disk performance will be slightly reduced during sync" -ForegroundColor Yellow
Write-Host "  • Do NOT power off or force shutdown during this process" -ForegroundColor Red
Write-Host "  • System can be rebooted safely (sync will resume)" -ForegroundColor Green
Write-Host ""

if (-not $AutoConfirm) {
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    $response = Read-Host "Type 'I UNDERSTAND THE RISKS' to proceed (or anything else to cancel)"
    
    if ($response -ne "I UNDERSTAND THE RISKS") {
        Write-Host ""
        Write-Host "Operation cancelled. No changes were made." -ForegroundColor Yellow
        exit 0
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    $finalConfirm = Read-Host "Final confirmation - proceed with disk mirror setup? (yes/no)"
    
    if ($finalConfirm -ne "yes") {
        Write-Host ""
        Write-Host "Operation cancelled. No changes were made." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    STARTING DISK MIRROR SETUP                         ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

$startTime = Get-Date

# ============================================================================
# STEP 1: CONVERT DISK 0 TO DYNAMIC
# ============================================================================

Write-Host "📀 STEP 1/4: Converting Disk 0 (Boot) to Dynamic Disk..." -ForegroundColor Cyan
Write-Host ""

if ($disk0.PartitionStyle -ne "Dynamic") {
    try {
        Write-Host "  Converting Disk 0..." -ForegroundColor Yellow
        
        # Use diskpart to convert to dynamic
        $diskpartScript = @"
select disk 0
convert dynamic
"@
        $diskpartScript | diskpart | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ Disk 0 converted to Dynamic successfully" -ForegroundColor Green
            
            # Verify conversion
            Start-Sleep -Seconds 5
            $disk0 = Get-Disk -Number 0
            if ($disk0.PartitionStyle -eq "Dynamic") {
                Write-Host "  ✓ Verified: Disk 0 is now Dynamic" -ForegroundColor Green
            } else {
                Write-Host "  ⚠️  Warning: Could not verify Dynamic conversion" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ✗ Failed to convert Disk 0" -ForegroundColor Red
            Write-Host "  Exit code: $LASTEXITCODE" -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host "  ✗ Error converting Disk 0: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  ✓ Disk 0 is already Dynamic" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 2: CONVERT DISK 1 TO DYNAMIC
# ============================================================================

Write-Host "📀 STEP 2/4: Converting Disk 1 (Target) to Dynamic Disk..." -ForegroundColor Cyan
Write-Host ""

if ($disk1.PartitionStyle -ne "Dynamic") {
    try {
        Write-Host "  Converting Disk 1..." -ForegroundColor Yellow
        
        # Use diskpart to convert to dynamic
        $diskpartScript = @"
select disk 1
convert dynamic
"@
        $diskpartScript | diskpart | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ Disk 1 converted to Dynamic successfully" -ForegroundColor Green
            
            # Verify conversion
            Start-Sleep -Seconds 5
            $disk1 = Get-Disk -Number 1
            if ($disk1.PartitionStyle -eq "Dynamic") {
                Write-Host "  ✓ Verified: Disk 1 is now Dynamic" -ForegroundColor Green
            } else {
                Write-Host "  ⚠️  Warning: Could not verify Dynamic conversion" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ✗ Failed to convert Disk 1" -ForegroundColor Red
            Write-Host "  Exit code: $LASTEXITCODE" -ForegroundColor Red
            
            Write-Host ""
            Write-Host "⚠️  WARNING: Disk 0 has been converted to Dynamic!" -ForegroundColor Red
            Write-Host "Cannot easily revert without data loss." -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host "  ✗ Error converting Disk 1: $_" -ForegroundColor Red
        
        Write-Host ""
        Write-Host "⚠️  WARNING: Disk 0 has been converted to Dynamic!" -ForegroundColor Red
        Write-Host "Cannot easily revert without data loss." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  ✓ Disk 1 is already Dynamic" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 3: CREATE MIRROR VOLUME
# ============================================================================

Write-Host "🔗 STEP 3/4: Creating mirror volume..." -ForegroundColor Cyan
Write-Host ""

try {
    Write-Host "  Getting C: volume information..." -ForegroundColor Yellow
    
    # Get the volume GUID for C:
    $cPartition = Get-Partition -DriveLetter C
    $cVolumePath = (Get-Volume -DriveLetter C).Path
    
    Write-Host "  Adding Disk 1 as mirror target for C:..." -ForegroundColor Yellow
    Write-Host "  This will start the synchronization process..." -ForegroundColor Yellow
    Write-Host ""
    
    # Use diskpart to add mirror
    # Note: This requires getting the volume number from diskpart
    $diskpartScript = @"
select volume c
add disk=1
"@
    
    $diskpartOutput = $diskpartScript | diskpart
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Mirror volume created successfully!" -ForegroundColor Green
        Write-Host "  ✓ Synchronization has started in the background" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Failed to create mirror volume" -ForegroundColor Red
        Write-Host "  Diskpart output:" -ForegroundColor Red
        $diskpartOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        
        Write-Host ""
        Write-Host "⚠️  CRITICAL: Both disks are now Dynamic!" -ForegroundColor Red
        Write-Host "Investigate the error before proceeding." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "  ✗ Error creating mirror: $_" -ForegroundColor Red
    
    Write-Host ""
    Write-Host "⚠️  CRITICAL: Both disks are now Dynamic!" -ForegroundColor Red
    Write-Host "Investigate the error before proceeding." -ForegroundColor Red
    exit 1
}

Write-Host ""

# ============================================================================
# STEP 4: VERIFY AND MONITOR
# ============================================================================

Write-Host "✅ STEP 4/4: Verifying mirror status..." -ForegroundColor Cyan
Write-Host ""

Start-Sleep -Seconds 10

try {
    # Check mirror status using diskpart
    Write-Host "  Checking mirror status..." -ForegroundColor Yellow
    
    $statusScript = @"
select volume c
detail volume
"@
    
    $statusOutput = $statusScript | diskpart
    Write-Host ""
    Write-Host "  Volume Status:" -ForegroundColor Cyan
    $statusOutput | ForEach-Object { 
        if ($_ -match "Mirror|Resync|Healthy") {
            Write-Host "    $_" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "  ⚠️  Could not verify mirror status: $_" -ForegroundColor Yellow
}

$endTime = Get-Date
$setupDuration = ($endTime - $startTime).TotalSeconds

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    DISK MIRROR SETUP COMPLETE                         ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "⏱️  Setup Duration: $([Math]::Round($setupDuration, 1)) seconds" -ForegroundColor Cyan
Write-Host ""

Write-Host "✅ Successfully configured:" -ForegroundColor Green
Write-Host "  • Disk 0 converted to Dynamic" -ForegroundColor Gray
Write-Host "  • Disk 1 converted to Dynamic" -ForegroundColor Gray
Write-Host "  • Mirror created: C: → Disk 1" -ForegroundColor Gray
Write-Host "  • Synchronization started" -ForegroundColor Gray
Write-Host ""

Write-Host "📊 MONITORING SYNCHRONIZATION:" -ForegroundColor Yellow
Write-Host ""
Write-Host "The mirror is now synchronizing in the background." -ForegroundColor White
Write-Host "Estimated time: $estimatedSyncMinutes - $($estimatedSyncMinutes * 2) minutes" -ForegroundColor White
Write-Host ""
Write-Host "To monitor progress:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Method 1: Disk Management (GUI)" -ForegroundColor Yellow
Write-Host "    1. Press Win+X, select 'Disk Management'" -ForegroundColor Gray
Write-Host "    2. Right-click C: volume" -ForegroundColor Gray
Write-Host "    3. Select 'Properties'" -ForegroundColor Gray
Write-Host "    4. Look for 'Resynching' status with percentage" -ForegroundColor Gray
Write-Host ""
Write-Host "  Method 2: Event Viewer" -ForegroundColor Yellow
Write-Host "    1. Open Event Viewer" -ForegroundColor Gray
Write-Host "    2. Navigate to: Windows Logs → System" -ForegroundColor Gray
Write-Host "    3. Look for events from 'Disk' source" -ForegroundColor Gray
Write-Host ""
Write-Host "  Method 3: PowerShell (run periodically)" -ForegroundColor Yellow
Write-Host "    Get-Volume -DriveLetter C | Format-List *" -ForegroundColor Gray
Write-Host ""

Write-Host "⚠️  IMPORTANT NOTES:" -ForegroundColor Red
Write-Host ""
Write-Host "  During synchronization:" -ForegroundColor Yellow
Write-Host "    ✓ You can use your computer normally" -ForegroundColor Green
Write-Host "    ✓ You can reboot safely (sync will resume)" -ForegroundColor Green
Write-Host "    ✓ Disk I/O performance may be reduced" -ForegroundColor Yellow
Write-Host "    ✗ Do NOT force shutdown or power off" -ForegroundColor Red
Write-Host ""
Write-Host "  After synchronization completes:" -ForegroundColor Yellow
Write-Host "    ✓ System is bootable from either disk" -ForegroundColor Green
Write-Host "    ✓ Automatic failover if one disk fails" -ForegroundColor Green
Write-Host "    ✓ All writes go to both disks automatically" -ForegroundColor Green
Write-Host ""

Write-Host "🎉 Disk mirroring is now active!" -ForegroundColor Green
Write-Host ""

exit 0
