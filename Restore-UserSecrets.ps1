<#
.SYNOPSIS
    Safely restores user secrets from a backup location.
    
.DESCRIPTION
    This script carefully restores user secrets (SSH keys, cloud credentials, configs)
    from a backup location. It:
    - Creates backups of existing files before overwriting
    - Shows diffs for text files
    - Asks for confirmation on conflicts
    - Provides rollback capability
    
.PARAMETER BackupPath
    Path to the backup containing user secrets. Default: E:\backups\users\david
    
.PARAMETER DryRun
    Show what would be restored without making changes.
    
.PARAMETER SafeOnly
    Only restore items that don't exist currently (no conflicts). Skips items that would overwrite existing files.
    
.EXAMPLE
    .\Restore-UserSecrets.ps1 -DryRun
    
.EXAMPLE
    .\Restore-UserSecrets.ps1 -SafeOnly
    
.EXAMPLE
    .\Restore-UserSecrets.ps1 -BackupPath "E:\backups\users\david"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$BackupPath = "E:\backups\users\david",
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,
    
    [Parameter(Mandatory=$false)]
    [switch]$SafeOnly
)

# Ensure running as user (not system)
if ($env:USERNAME -eq "SYSTEM") {
    Write-Host "⚠️  Do not run this script as SYSTEM. Run as your user account." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    USER SECRETS RESTORE UTILITY                       ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$currentUserPath = $env:USERPROFILE
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$rollbackPath = Join-Path $env:TEMP "UserSecrets-Rollback-$timestamp"

# Verify backup exists
if (-not (Test-Path $BackupPath)) {
    Write-Host "❌ Backup path not found: $BackupPath" -ForegroundColor Red
    exit 1
}

Write-Host "Backup source: $BackupPath" -ForegroundColor Cyan
Write-Host "Restore target: $currentUserPath" -ForegroundColor Cyan
Write-Host "Rollback backup: $rollbackPath" -ForegroundColor Gray
Write-Host ""

# Define secrets to restore (in order of priority)
$secretItems = @(
    # Critical credentials
    @{Path=".ssh"; Type="Folder"; Critical=$true; Description="SSH keys and config"}
    @{Path=".aws"; Type="Folder"; Critical=$true; Description="AWS credentials"}
    @{Path=".azure"; Type="Folder"; Critical=$true; Description="Azure credentials"}
    @{Path=".kube"; Type="Folder"; Critical=$true; Description="Kubernetes config"}
    @{Path="Keys"; Type="Folder"; Critical=$true; Description="Custom keys"}
    
    # Docker and container tools
    @{Path=".docker"; Type="Folder"; Critical=$false; Description="Docker config"}
    
    # Development configs
    @{Path=".gitconfig"; Type="File"; Critical=$false; Description="Git global config"}
    @{Path=".nuget"; Type="Folder"; Critical=$false; Description="NuGet config"}
    @{Path=".config"; Type="Folder"; Critical=$false; Description="App configs"}
    
    # Cloud/service configs
    @{Path=".azcopy"; Type="Folder"; Critical=$false; Description="AzCopy config"}
    @{Path=".talos"; Type="Folder"; Critical=$false; Description="Talos config"}
    @{Path=".ollama"; Type="Folder"; Critical=$false; Description="Ollama config"}
)

# Analysis phase
Write-Host "🔍 Analyzing secrets to restore..." -ForegroundColor Cyan
Write-Host ""

$toRestore = @()
$conflicts = @()
$safeRestores = @()

foreach ($item in $secretItems) {
    $backupItemPath = Join-Path $BackupPath $item.Path
    $currentItemPath = Join-Path $currentUserPath $item.Path
    
    if (Test-Path $backupItemPath) {
        $itemInfo = @{
            Item = $item
            BackupPath = $backupItemPath
            CurrentPath = $currentItemPath
            Exists = (Test-Path $currentItemPath)
        }
        
        $toRestore += $itemInfo
        
        if ($itemInfo.Exists) {
            $conflicts += $itemInfo
        } else {
            $safeRestores += $itemInfo
        }
    }
}

# Display summary
Write-Host "📊 Restore Summary:" -ForegroundColor Yellow
Write-Host "  Total items to restore: $($toRestore.Count)" -ForegroundColor Gray
Write-Host "  Safe restores (no conflicts): $($safeRestores.Count)" -ForegroundColor Green
Write-Host "  Conflicts (will overwrite): $($conflicts.Count)" -ForegroundColor $(if($conflicts.Count -gt 0){'Yellow'}else{'Green'})
Write-Host ""

if ($safeRestores.Count -gt 0) {
    Write-Host "✅ Safe to restore (no conflicts):" -ForegroundColor Green
    foreach ($restore in $safeRestores) {
        Write-Host "  • $($restore.Item.Path) - $($restore.Item.Description)" -ForegroundColor Gray
    }
    Write-Host ""
}

if ($conflicts.Count -gt 0) {
    if ($SafeOnly) {
        Write-Host "⚠️  Items with conflicts (WILL BE SKIPPED in SafeOnly mode):" -ForegroundColor Yellow
    } else {
        Write-Host "⚠️  Items with conflicts (will backup existing first):" -ForegroundColor Yellow
    }
    foreach ($conflict in $conflicts) {
        Write-Host "  • $($conflict.Item.Path) - $($conflict.Item.Description)" -ForegroundColor Gray
        
        # For .gitconfig, show diff if it's a file
        if ($conflict.Item.Path -eq ".gitconfig" -and $conflict.Item.Type -eq "File") {
            Write-Host "    Checking differences..." -ForegroundColor Cyan
            try {
                $backupContent = Get-Content $conflict.BackupPath -Raw
                $currentContent = Get-Content $conflict.CurrentPath -Raw
                
                if ($backupContent -ne $currentContent) {
                    Write-Host "    📝 Files differ - review recommended" -ForegroundColor Yellow
                } else {
                    Write-Host "    ✓ Files are identical" -ForegroundColor Green
                }
            } catch {
                Write-Host "    ⚠️  Could not compare: $_" -ForegroundColor Yellow
            }
        }
    }
    Write-Host ""
}

if ($SafeOnly -and $conflicts.Count -gt 0) {
    Write-Host "ℹ️  SafeOnly mode: Only items without conflicts will be restored." -ForegroundColor Cyan
    Write-Host ""
}

if ($DryRun) {
    Write-Host "=== DRY RUN - No changes will be made ===" -ForegroundColor Magenta
    Write-Host ""
    exit 0
}

# Confirmation
if (-not $Force) {
    if ($SafeOnly) {
        Write-Host "ℹ️  SafeOnly mode: Only restoring $($safeRestores.Count) items without conflicts." -ForegroundColor Cyan
    } else {
        Write-Host "⚠️  WARNING: This will restore backed-up secrets to your profile." -ForegroundColor Yellow
        Write-Host "Existing files will be backed up to: $rollbackPath" -ForegroundColor Yellow
    }
    Write-Host ""
    $response = Read-Host "Continue? (yes/no)"
    
    if ($response -ne "yes") {
        Write-Host "Cancelled by user." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# Filter items based on SafeOnly mode
$itemsToProcess = if ($SafeOnly) { 
    Write-Host "🔒 SafeOnly mode: Skipping items with conflicts" -ForegroundColor Cyan
    $safeRestores 
} else { 
    $toRestore 
}

# Create rollback directory
New-Item -ItemType Directory -Path $rollbackPath -Force | Out-Null
Write-Host "📦 Created rollback backup location" -ForegroundColor Green
Write-Host ""

# Restore process
$restored = 0
$failed = 0

Write-Host "🔄 Restoring secrets..." -ForegroundColor Cyan
Write-Host ""

foreach ($restore in $itemsToProcess) {
    $itemPath = $restore.Item.Path
    Write-Host "Processing: $itemPath" -ForegroundColor Cyan
    
    try {
        # Backup existing if it exists
        if ($restore.Exists) {
            $rollbackItemPath = Join-Path $rollbackPath $itemPath
            $rollbackParent = Split-Path $rollbackItemPath -Parent
            
            if (-not (Test-Path $rollbackParent)) {
                New-Item -ItemType Directory -Path $rollbackParent -Force | Out-Null
            }
            
            Write-Host "  → Backing up existing to rollback folder..." -ForegroundColor Yellow
            
            if ($restore.Item.Type -eq "Folder") {
                Copy-Item -Path $restore.CurrentPath -Destination $rollbackItemPath -Recurse -Force
            } else {
                Copy-Item -Path $restore.CurrentPath -Destination $rollbackItemPath -Force
            }
        }
        
        # Restore from backup
        Write-Host "  → Restoring from backup..." -ForegroundColor Green
        
        if ($restore.Item.Type -eq "Folder") {
            # Remove existing if present
            if ($restore.Exists) {
                Remove-Item -Path $restore.CurrentPath -Recurse -Force
            }
            
            Copy-Item -Path $restore.BackupPath -Destination $restore.CurrentPath -Recurse -Force
        } else {
            Copy-Item -Path $restore.BackupPath -Destination $restore.CurrentPath -Force
        }
        
        Write-Host "  ✓ Restored successfully" -ForegroundColor Green
        $restored++
        
        # Special handling for SSH keys - set permissions
        if ($itemPath -eq ".ssh") {
            Write-Host "  → Setting SSH key permissions..." -ForegroundColor Cyan
            $sshPath = $restore.CurrentPath
            
            # Remove inheritance and set restrictive permissions on private keys
            Get-ChildItem -Path $sshPath -File | Where-Object { $_.Name -notmatch '\.(pub|ppk)$' } | ForEach-Object {
                try {
                    $acl = Get-Acl $_.FullName
                    $acl.SetAccessRuleProtection($true, $false)
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $env:USERNAME, "FullControl", "Allow"
                    )
                    $acl.SetAccessRule($rule)
                    Set-Acl $_.FullName $acl
                    Write-Host "    ✓ Secured: $($_.Name)" -ForegroundColor Gray
                } catch {
                    Write-Host "    ⚠️  Could not set permissions on $($_.Name): $_" -ForegroundColor Yellow
                }
            }
        }
        
    } catch {
        Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        $failed++
    }
    
    Write-Host ""
}

# Summary
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                          RESTORE COMPLETE                             ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "📊 Results:" -ForegroundColor Cyan
Write-Host "  Restored: $restored" -ForegroundColor Green
Write-Host "  Failed: $failed" -ForegroundColor $(if($failed -gt 0){'Red'}else{'Green'})
Write-Host ""

if ($restored -gt 0) {
    Write-Host "✅ Secrets have been restored!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Rollback location: $rollbackPath" -ForegroundColor Yellow
    Write-Host "Keep this backup in case you need to revert." -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "⚠️  Important next steps:" -ForegroundColor Cyan
    Write-Host "  1. Test SSH keys: ssh -T git@github.com" -ForegroundColor Gray
    Write-Host "  2. Test cloud credentials: aws sts get-caller-identity" -ForegroundColor Gray
    Write-Host "  3. Review Git config: git config --global --list" -ForegroundColor Gray
    Write-Host "  4. If everything works, you can delete: $rollbackPath" -ForegroundColor Gray
    Write-Host ""
}

if ($failed -gt 0) {
    Write-Host "⚠️  Some items failed to restore. Check errors above." -ForegroundColor Yellow
    exit 1
}

exit 0
