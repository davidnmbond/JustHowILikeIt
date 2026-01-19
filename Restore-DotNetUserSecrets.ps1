<#
.SYNOPSIS
    Restores .NET User Secrets from a backup location.
    
.DESCRIPTION
    This script restores .NET User Secrets (secrets.json files) used by ASP.NET Core
    and other .NET applications. User Secrets are stored per-project using GUIDs.
    
.PARAMETER BackupPath
    Path to the backup containing AppData. Default: E:\backups\users\david
    
.PARAMETER DryRun
    Show what would be restored without making changes.
    
.PARAMETER Merge
    When specified, keeps existing secrets and only adds missing ones.
    
.EXAMPLE
    .\Restore-DotNetUserSecrets.ps1 -DryRun
    
.EXAMPLE
    .\Restore-DotNetUserSecrets.ps1
    
.EXAMPLE
    .\Restore-DotNetUserSecrets.ps1 -Merge
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$BackupPath = "E:\backups\users\david",
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [switch]$Merge
)

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║               .NET USER SECRETS RESTORE UTILITY                       ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$currentSecretsPath = Join-Path $env:APPDATA "Microsoft\UserSecrets"
$backupSecretsPath = Join-Path $BackupPath "AppData\Roaming\Microsoft\UserSecrets"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$rollbackPath = Join-Path $env:TEMP "DotNetUserSecrets-Rollback-$timestamp"

# Verify backup exists
if (-not (Test-Path $backupSecretsPath)) {
    Write-Host "❌ Backup User Secrets not found at: $backupSecretsPath" -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected location: [BackupPath]\AppData\Roaming\Microsoft\UserSecrets" -ForegroundColor Yellow
    exit 1
}

Write-Host "Backup source: $backupSecretsPath" -ForegroundColor Cyan
Write-Host "Restore target: $currentSecretsPath" -ForegroundColor Cyan
Write-Host "Rollback backup: $rollbackPath" -ForegroundColor Gray
Write-Host ""

# Analyze secrets
Write-Host "🔍 Analyzing User Secrets..." -ForegroundColor Cyan
Write-Host ""

$backupSecrets = Get-ChildItem -Path $backupSecretsPath -Directory
$currentSecrets = if (Test-Path $currentSecretsPath) { 
    Get-ChildItem -Path $currentSecretsPath -Directory 
} else { 
    @() 
}

Write-Host "Backup contains: $($backupSecrets.Count) secret configurations" -ForegroundColor Gray
Write-Host "Current has: $($currentSecrets.Count) secret configurations" -ForegroundColor Gray
Write-Host ""

# Categorize secrets
$newSecrets = @()
$existingSecrets = @()
$currentSecretIds = $currentSecrets | ForEach-Object { $_.Name }

foreach ($backupSecret in $backupSecrets) {
    $secretId = $backupSecret.Name
    $secretFile = Join-Path $backupSecret.FullName "secrets.json"
    
    if (-not (Test-Path $secretFile)) {
        continue  # Skip folders without secrets.json
    }
    
    $currentSecretPath = Join-Path $currentSecretsPath $secretId
    $currentSecretFile = Join-Path $currentSecretPath "secrets.json"
    
    $secretInfo = @{
        Id = $secretId
        BackupPath = $secretFile
        CurrentPath = $currentSecretFile
        Exists = (Test-Path $currentSecretFile)
    }
    
    if ($secretInfo.Exists) {
        $existingSecrets += $secretInfo
    } else {
        $newSecrets += $secretInfo
    }
}

# Display analysis
Write-Host "📊 Analysis:" -ForegroundColor Yellow
Write-Host "  New secrets (safe to restore): $($newSecrets.Count)" -ForegroundColor Green
Write-Host "  Existing secrets (will be handled based on mode): $($existingSecrets.Count)" -ForegroundColor $(if($existingSecrets.Count -gt 0){'Yellow'}else{'Green'})
Write-Host ""

if ($Merge) {
    Write-Host "🔀 MERGE MODE: Existing secrets will be kept, only new ones added" -ForegroundColor Cyan
} else {
    Write-Host "♻️  REPLACE MODE: All secrets will be restored from backup" -ForegroundColor Yellow
    if ($existingSecrets.Count -gt 0) {
        Write-Host "   (Existing secrets will be backed up first)" -ForegroundColor Yellow
    }
}
Write-Host ""

if ($newSecrets.Count -gt 0) {
    Write-Host "✅ Secrets to restore (no conflicts):" -ForegroundColor Green
    $newSecrets | Select-Object -First 10 | ForEach-Object {
        Write-Host "  • $($_.Id)" -ForegroundColor Gray
    }
    if ($newSecrets.Count -gt 10) {
        Write-Host "  ... and $($newSecrets.Count - 10) more" -ForegroundColor Gray
    }
    Write-Host ""
}

if ($existingSecrets.Count -gt 0) {
    if ($Merge) {
        Write-Host "⏭️  Secrets to skip (already exist):" -ForegroundColor Yellow
    } else {
        Write-Host "♻️  Secrets to replace (will backup first):" -ForegroundColor Yellow
    }
    $existingSecrets | Select-Object -First 10 | ForEach-Object {
        Write-Host "  • $($_.Id)" -ForegroundColor Gray
    }
    if ($existingSecrets.Count -gt 10) {
        Write-Host "  ... and $($existingSecrets.Count - 10) more" -ForegroundColor Gray
    }
    Write-Host ""
}

if ($DryRun) {
    Write-Host "=== DRY RUN - No changes will be made ===" -ForegroundColor Magenta
    Write-Host ""
    exit 0
}

# Confirmation
$totalToRestore = if ($Merge) { $newSecrets.Count } else { $newSecrets.Count + $existingSecrets.Count }
Write-Host "Ready to restore $totalToRestore secret configuration(s)." -ForegroundColor Cyan
$response = Read-Host "Continue? (yes/no)"

if ($response -ne "yes") {
    Write-Host "Cancelled by user." -ForegroundColor Yellow
    exit 0
}
Write-Host ""

# Ensure target directory exists
if (-not (Test-Path $currentSecretsPath)) {
    Write-Host "Creating User Secrets directory..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $currentSecretsPath -Force | Out-Null
}

# Create rollback directory
New-Item -ItemType Directory -Path $rollbackPath -Force | Out-Null
Write-Host "📦 Created rollback backup location" -ForegroundColor Green
Write-Host ""

# Restore process
$restored = 0
$skipped = 0
$failed = 0

Write-Host "🔄 Restoring User Secrets..." -ForegroundColor Cyan
Write-Host ""

# Restore new secrets
foreach ($secret in $newSecrets) {
    try {
        $targetDir = Split-Path $secret.CurrentPath -Parent
        
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        
        Copy-Item -Path $secret.BackupPath -Destination $secret.CurrentPath -Force
        Write-Host "  ✓ Restored: $($secret.Id)" -ForegroundColor Green
        $restored++
    } catch {
        Write-Host "  ✗ Failed: $($secret.Id) - $_" -ForegroundColor Red
        $failed++
    }
}

# Handle existing secrets
foreach ($secret in $existingSecrets) {
    if ($Merge) {
        Write-Host "  ⏭️  Skipped (exists): $($secret.Id)" -ForegroundColor Gray
        $skipped++
    } else {
        try {
            # Backup existing
            $rollbackFile = Join-Path $rollbackPath "$($secret.Id)-secrets.json"
            Copy-Item -Path $secret.CurrentPath -Destination $rollbackFile -Force
            
            # Restore from backup
            Copy-Item -Path $secret.BackupPath -Destination $secret.CurrentPath -Force
            Write-Host "  ♻️  Replaced: $($secret.Id)" -ForegroundColor Yellow
            $restored++
        } catch {
            Write-Host "  ✗ Failed: $($secret.Id) - $_" -ForegroundColor Red
            $failed++
        }
    }
}

# Summary
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                          RESTORE COMPLETE                             ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "📊 Results:" -ForegroundColor Cyan
Write-Host "  Restored: $restored" -ForegroundColor Green
Write-Host "  Skipped: $skipped" -ForegroundColor Gray
Write-Host "  Failed: $failed" -ForegroundColor $(if($failed -gt 0){'Red'}else{'Green'})
Write-Host ""

if ($restored -gt 0) {
    Write-Host "✅ .NET User Secrets have been restored!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Rollback location: $rollbackPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "ℹ️  User Secrets are project-specific and referenced by GUID." -ForegroundColor Cyan
    Write-Host "Your .NET projects will now have access to these secrets." -ForegroundColor Gray
    Write-Host ""
    Write-Host "To list secrets for a project:" -ForegroundColor Cyan
    Write-Host "  cd [project-directory]" -ForegroundColor Gray
    Write-Host "  dotnet user-secrets list" -ForegroundColor Gray
    Write-Host ""
}

if ($failed -gt 0) {
    Write-Host "⚠️  Some secrets failed to restore. Check errors above." -ForegroundColor Yellow
    exit 1
}

exit 0
