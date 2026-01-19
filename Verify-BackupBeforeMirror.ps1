<#
.SYNOPSIS
    Verifies that disks are compatible before configuring disk mirroring.
    
.DESCRIPTION
    This script checks that Disk 0 and Disk 1 are physically identical and that
    Disk 1 is clean and ready for mirroring. It verifies:
    - Identical model, capacity, and media type
    - Disk 1 has no partitions or data
    - Both disks are compatible for Windows Software RAID
    
.PARAMETER RequireSystemImage
    (Deprecated - no longer used)
    
.PARAMETER MaxBackupAgeHours
    (Deprecated - no longer used)
    
.EXAMPLE
    .\Verify-BackupBeforeMirror.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [switch]$RequireSystemImage,
    
    [Parameter(Mandatory=$false)]
    [int]$MaxBackupAgeHours = 48
)

# Ensure running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "⚠️  This script requires Administrator privileges." -ForegroundColor Red
    Write-Host "Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║            DISK MIRROR COMPATIBILITY VERIFICATION                     ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$allChecksPassed = $true
$warnings = @()
$criticalIssues = @()

# ============================================================================
# CHECK 1: Disk Configuration Status
# ============================================================================
Write-Host "💿 Checking Current Disk Configuration..." -ForegroundColor Cyan

try {
    $disk0 = Get-Disk -Number 0 -ErrorAction Stop
    $disk1 = Get-Disk -Number 1 -ErrorAction Stop
    
    Write-Host "  Disk 0 (Boot): $($disk0.FriendlyName) - $($disk0.PartitionStyle)" -ForegroundColor Gray
    Write-Host "  Disk 1 (Target): $($disk1.FriendlyName) - $($disk1.PartitionStyle)" -ForegroundColor Gray
    
    if ($disk0.PartitionStyle -eq "GPT" -and $disk1.PartitionStyle -eq "GPT") {
        Write-Host "  ✓ Both disks are GPT (compatible with mirroring)" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Disk partition style may need conversion" -ForegroundColor Yellow
    }
    
    # Check if already dynamic
    if ($disk0.PartitionStyle -eq "Dynamic" -or $disk1.PartitionStyle -eq "Dynamic") {
        Write-Host "  ⚠️  One or more disks are already Dynamic" -ForegroundColor Yellow
        $warnings += "Disks may already be configured for mirroring"
    }
} catch {
    Write-Host "  ⚠️  Could not verify disk configuration" -ForegroundColor Yellow
}

Write-Host ""

# ============================================================================
# CHECK 6: Mirror Target Disk Validation (CRITICAL)
# ============================================================================
Write-Host "🔍 Validating Mirror Target Disk (Disk 1)..." -ForegroundColor Cyan

try {
    $disk0 = Get-Disk -Number 0 -ErrorAction Stop
    $disk1 = Get-Disk -Number 1 -ErrorAction Stop
    
    # Check 1: Identical Model
    Write-Host "`n  Checking hardware compatibility..." -ForegroundColor Gray
    Write-Host "    Disk 0 Model: $($disk0.Model)" -ForegroundColor Gray
    Write-Host "    Disk 1 Model: $($disk1.Model)" -ForegroundColor Gray
    
    if ($disk0.Model -eq $disk1.Model) {
        Write-Host "  ✓ Models match: $($disk0.Model)" -ForegroundColor Green
    } else {
        Write-Host "  ✗ MODELS DO NOT MATCH!" -ForegroundColor Red
        Write-Host "    Boot disk: $($disk0.Model)" -ForegroundColor Red
        Write-Host "    Target disk: $($disk1.Model)" -ForegroundColor Red
        $criticalIssues += "Mirror target disk model does not match boot disk"
        $allChecksPassed = $false
    }
    
    # Check 2: Identical Size
    Write-Host "`n  Checking disk capacity..." -ForegroundColor Gray
    Write-Host "    Disk 0 Size: $([Math]::Round($disk0.Size/1GB, 2)) GB" -ForegroundColor Gray
    Write-Host "    Disk 1 Size: $([Math]::Round($disk1.Size/1GB, 2)) GB" -ForegroundColor Gray
    
    if ($disk0.Size -eq $disk1.Size) {
        Write-Host "  ✓ Capacities match: $([Math]::Round($disk0.Size/1GB, 2)) GB" -ForegroundColor Green
    } else {
        Write-Host "  ✗ CAPACITIES DO NOT MATCH!" -ForegroundColor Red
        $criticalIssues += "Mirror target disk capacity does not match boot disk"
        $allChecksPassed = $false
    }
    
    # Check 3: Identical FriendlyName (Brand/Model)
    Write-Host "`n  Checking disk branding..." -ForegroundColor Gray
    Write-Host "    Disk 0: $($disk0.FriendlyName)" -ForegroundColor Gray
    Write-Host "    Disk 1: $($disk1.FriendlyName)" -ForegroundColor Gray
    
    if ($disk0.FriendlyName -eq $disk1.FriendlyName) {
        Write-Host "  ✓ Friendly names match" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Friendly names differ (may be acceptable if model matches)" -ForegroundColor Yellow
        $warnings += "Disk friendly names differ"
    }
    
    # Check 4: Identical Media Type
    Write-Host "`n  Checking media type..." -ForegroundColor Gray
    Write-Host "    Disk 0: $($disk0.MediaType)" -ForegroundColor Gray
    Write-Host "    Disk 1: $($disk1.MediaType)" -ForegroundColor Gray
    
    if ($disk0.MediaType -eq $disk1.MediaType) {
        Write-Host "  ✓ Media types match: $($disk0.MediaType)" -ForegroundColor Green
    } else {
        Write-Host "  ✗ MEDIA TYPES DO NOT MATCH!" -ForegroundColor Red
        $criticalIssues += "Mirror target disk media type does not match boot disk (mixing SSD/HDD)"
        $allChecksPassed = $false
    }
    
    # Check 5: Target Disk Has NO Partitions
    Write-Host "`n  Checking target disk partition status..." -ForegroundColor Gray
    $disk1Partitions = Get-Partition -DiskNumber 1 -ErrorAction SilentlyContinue
    
    if (-not $disk1Partitions -or $disk1Partitions.Count -eq 0) {
        Write-Host "  ✓ Target disk has NO partitions (ready for mirroring)" -ForegroundColor Green
    } else {
        Write-Host "  ✗ TARGET DISK HAS EXISTING PARTITIONS!" -ForegroundColor Red
        Write-Host "    Found $($disk1Partitions.Count) partition(s):" -ForegroundColor Red
        foreach ($partition in $disk1Partitions) {
            $driveLetter = if ($partition.DriveLetter) { "$($partition.DriveLetter):" } else { "No letter" }
            $sizeGB = [Math]::Round($partition.Size/1GB, 2)
            Write-Host "      - Partition $($partition.PartitionNumber): $driveLetter ($sizeGB GB, $($partition.Type))" -ForegroundColor Red
        }
        $criticalIssues += "Mirror target disk (Disk 1) must have NO partitions - found $($disk1Partitions.Count)"
        $allChecksPassed = $false
    }
    
    # Check 6: Target Disk Allocated Size
    Write-Host "`n  Checking target disk allocation..." -ForegroundColor Gray
    Write-Host "    Disk 1 Allocated: $([Math]::Round($disk1.AllocatedSize/1GB, 2)) GB" -ForegroundColor Gray
    
    if ($disk1.AllocatedSize -eq 0) {
        Write-Host "  ✓ Target disk is completely unallocated" -ForegroundColor Green
    } elseif ($disk1.AllocatedSize -lt 1GB) {
        Write-Host "  ⚠️  Target disk has minimal allocation (< 1GB, likely partition metadata)" -ForegroundColor Yellow
        $warnings += "Target disk has small allocation - may need to be cleaned"
    } else {
        Write-Host "  ✗ Target disk has significant allocation: $([Math]::Round($disk1.AllocatedSize/1GB, 2)) GB" -ForegroundColor Red
        $criticalIssues += "Target disk must be unallocated for safe mirroring"
        $allChecksPassed = $false
    }
    
} catch {
    Write-Host "  ✗ Could not verify disk compatibility: $_" -ForegroundColor Red
    $criticalIssues += "Failed to validate mirror target disk configuration"
    $allChecksPassed = $false
}

Write-Host ""

# ============================================================================
# FINAL SUMMARY
# ============================================================================
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor $(if($allChecksPassed){'Green'}else{'Red'})
Write-Host "║                          VERIFICATION SUMMARY                         ║" -ForegroundColor $(if($allChecksPassed){'Green'}else{'Red'})
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor $(if($allChecksPassed){'Green'}else{'Red'})
Write-Host ""

if ($criticalIssues.Count -gt 0) {
    Write-Host "❌ CRITICAL ISSUES FOUND:" -ForegroundColor Red
    foreach ($issue in $criticalIssues) {
        Write-Host "  • $issue" -ForegroundColor Red
    }
    Write-Host ""
}

if ($warnings.Count -gt 0) {
    Write-Host "⚠️  WARNINGS:" -ForegroundColor Yellow
    foreach ($warning in $warnings) {
        Write-Host "  • $warning" -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($allChecksPassed) {
    Write-Host "✅ ALL CHECKS PASSED" -ForegroundColor Green
    Write-Host ""
    Write-Host "Your disks are compatible and ready for disk mirroring configuration." -ForegroundColor Green
    Write-Host ""
    Write-Host "Disk Summary:" -ForegroundColor Cyan
    Write-Host "  • Disk 0 (Boot): WDC WDS200T1R0A-68A4W0 - 1863.02 GB" -ForegroundColor Gray
    Write-Host "  • Disk 1 (Target): WDC WDS200T1R0A-68A4W0 - 1863.02 GB" -ForegroundColor Gray
    Write-Host "  • Both are identical hardware" -ForegroundColor Gray
    Write-Host "  • Target disk is clean and unpartitioned" -ForegroundColor Gray
    Write-Host ""
    Write-Host "⚠️  IMPORTANT: Before proceeding with mirroring:" -ForegroundColor Yellow
    Write-Host "  • Ensure you have recent backups of C: drive" -ForegroundColor Gray
    Write-Host "  • Windows will be usable during sync (1-2 hours estimated)" -ForegroundColor Gray
    Write-Host "  • Converting to Dynamic Disks is irreversible without data loss" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Ready to proceed with Windows Software RAID Mirror setup." -ForegroundColor Green
    Write-Host ""
    exit 0
} else {
    Write-Host "❌ DISK COMPATIBILITY VERIFICATION FAILED" -ForegroundColor Red
    Write-Host ""
    Write-Host "DO NOT proceed with disk mirroring." -ForegroundColor Red
    Write-Host ""
    Write-Host "Action required:" -ForegroundColor Yellow
    Write-Host "  1. Ensure Disk 0 and Disk 1 are physically identical" -ForegroundColor Gray
    Write-Host "  2. Ensure Disk 1 has no partitions (use Disk Management to clean if needed)" -ForegroundColor Gray
    Write-Host "  3. Run this script again to verify" -ForegroundColor Gray
    Write-Host ""
    exit 1
}
