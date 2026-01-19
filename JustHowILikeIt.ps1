<#
.SYNOPSIS
    Automates the installation of developer tools using WinGet based on a configuration file.
    
.DESCRIPTION
    This script installs applications from a customizable configuration file.
    It supports WinGet package installation, Oh My Posh theming, and GitHub repository setup.
    Users can create their own config files to define their preferred tools and settings.
    
.PARAMETER ConfigFile
    Path to the JSON configuration file. If not specified, looks for a config file in the script directory.

.PARAMETER DryRun
    When specified, performs pre-flight checks and shows what would be installed without actually installing anything.
    
.EXAMPLE
    .\JustHowILikeIt.ps1 -ConfigFile ".\myconfig.json"
    
.EXAMPLE
    .\JustHowILikeIt.ps1 -DryRun
    Shows what would be installed without making any changes

.PARAMETER NoCache
    When specified, ignores any cached pre-flight status and performs fresh checks.
    
.EXAMPLE
    .\JustHowILikeIt.ps1
    (Uses default config file in script directory)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [switch]$NoCache
)

# Automatically set execution policy for this session to allow the script to run
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force

# Cache settings
$script:CacheFile = Join-Path (Split-Path -Parent $PSCommandPath) ".preflight-cache.json"
$script:CacheMaxAgeMinutes = 60  # Cache valid for 1 hour

# Function to load and validate configuration
function Get-Configuration {
    param([string]$ConfigPath)
    
    # If no config specified, look for default config files
    if ([string]::IsNullOrEmpty($ConfigPath)) {
        $scriptDir = Split-Path -Parent $PSCommandPath
        $possibleConfigs = @(
            (Join-Path $scriptDir "config.json"),
            (Join-Path $scriptDir "$env:USERNAME.config.json"),
            (Join-Path $scriptDir "david.config.json")
        )
        
        foreach ($config in $possibleConfigs) {
            if (Test-Path $config) {
                $ConfigPath = $config
                Write-Host "Using configuration file: $ConfigPath" -ForegroundColor Cyan
                break
            }
        }
        
        if ([string]::IsNullOrEmpty($ConfigPath)) {
            Write-Host "Error: No configuration file found. Please create a config.json file or specify -ConfigFile parameter." -ForegroundColor Red
            Write-Host "Example: .\JustHowILikeIt.ps1 -ConfigFile '.\myconfig.json'" -ForegroundColor Yellow
            exit 1
        }
    }
    
    # Verify config file exists
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "Error: Configuration file not found: $ConfigPath" -ForegroundColor Red
        exit 1
    }
    
    # Load and parse JSON
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        Write-Host "Configuration loaded successfully." -ForegroundColor Green
        return $config
    }
    catch {
        Write-Host "Error: Failed to parse configuration file: $_" -ForegroundColor Red
        exit 1
    }
}

# Load configuration
$config = Get-Configuration -ConfigPath $ConfigFile

# Function to check if cache is valid
function Test-CacheValid {
    if (-not (Test-Path $script:CacheFile)) {
        return $false
    }
    
    try {
        $cache = Get-Content $script:CacheFile -Raw | ConvertFrom-Json
        $cacheTime = [DateTime]::Parse($cache.LastUpdated)
        $age = (Get-Date) - $cacheTime
        
        if ($age.TotalMinutes -lt $script:CacheMaxAgeMinutes) {
            return $true
        }
    }
    catch {
        return $false
    }
    
    return $false
}

# Function to load cached status
function Get-CachedStatus {
    try {
        $cache = Get-Content $script:CacheFile -Raw | ConvertFrom-Json
        
        # Convert back to proper objects
        $status = @{
            Tools = @()
            GitHubCLI = $cache.GitHubCLI
            OhMyPosh = $cache.OhMyPosh
            Repository = $cache.Repository
            FirefoxExtensions = @()
            LastUpdated = $cache.LastUpdated
        }
        
        foreach ($tool in $cache.Tools) {
            $status.Tools += [PSCustomObject]@{
                Name = $tool.Name
                Id = $tool.Id
                Category = $tool.Category
                Installed = $tool.Installed
                Action = $tool.Action
            }
        }
        
        if ($cache.FirefoxExtensions) {
            foreach ($ext in $cache.FirefoxExtensions) {
                $status.FirefoxExtensions += [PSCustomObject]@{
                    Name = $ext.Name
                    Id = $ext.Id
                    Url = $ext.Url
                    Installed = $ext.Installed
                }
            }
        }
        
        return $status
    }
    catch {
        return $null
    }
}

# Function to save status to cache
function Save-StatusToCache {
    param($Status)
    
    $cacheData = @{
        LastUpdated = (Get-Date).ToString("o")
        Tools = $Status.Tools
        GitHubCLI = $Status.GitHubCLI
        OhMyPosh = $Status.OhMyPosh
        Repository = $Status.Repository
        FirefoxExtensions = $Status.FirefoxExtensions
    }
    
    $cacheData | ConvertTo-Json -Depth 10 | Set-Content $script:CacheFile -Force
}

# Function to check if a tool is already installed
function Test-ToolInstalled {
    param(
        [string]$ToolId
    )
    
    # Special case checks for tools that may not be tracked by winget
    switch ($ToolId) {
        "Microsoft.WSL" {
            # Check if wsl command exists
            if (Get-Command wsl -ErrorAction SilentlyContinue) {
                return $true
            }
        }
    }
    
    try {
        $checkInstalled = winget list --id $ToolId --exact --source winget 2>$null | Out-String
        return ($checkInstalled -match [regex]::Escape($ToolId))
    }
    catch {
        return $false
    }
}

# Function to perform pre-flight checks with progress bar
function Get-PreFlightStatus {
    param($Configuration)
    
    $status = @{
        Tools = @()
        GitHubCLI = $null
        OhMyPosh = $null
        Repository = $null
        FirefoxExtensions = @()
    }
    
    Write-Host "`n🔍 Running pre-flight checks..." -ForegroundColor Cyan
    
    $firefoxExtCount = if ($Configuration.firefoxExtensions) { 1 } else { 0 }
    $totalChecks = $Configuration.tools.Count + 3 + $firefoxExtCount  # tools + gh + posh + repo + firefox
    $currentCheck = 0
    
    # Check each tool with progress bar
    foreach ($tool in $Configuration.tools) {
        $currentCheck++
        $percentComplete = [int](($currentCheck / $totalChecks) * 100)
        Write-Progress -Activity "Pre-flight checks" -Status "Checking $($tool.name)..." -PercentComplete $percentComplete
        
        $isInstalled = Test-ToolInstalled -ToolId $tool.id
        $status.Tools += [PSCustomObject]@{
            Name = $tool.name
            Id = $tool.id
            Category = $tool.category
            Installed = $isInstalled
            Action = if ($isInstalled) { "Skip" } else { "Install" }
        }
    }
    
    # Check GitHub CLI
    $currentCheck++
    Write-Progress -Activity "Pre-flight checks" -Status "Checking GitHub CLI..." -PercentComplete ([int](($currentCheck / $totalChecks) * 100))
    
    $ghInstalled = Get-Command gh -ErrorAction SilentlyContinue
    if ($ghInstalled) {
        $authStatus = gh auth status 2>&1
        $isAuthenticated = $authStatus -match "Logged in to github.com"
        $status.GitHubCLI = [PSCustomObject]@{
            Installed = $true
            Authenticated = $isAuthenticated
            Action = if ($isAuthenticated) { "Skip auth" } else { "Authenticate" }
        }
    } else {
        $status.GitHubCLI = [PSCustomObject]@{
            Installed = $false
            Authenticated = $false
            Action = "Will be installed"
        }
    }
    
    # Check Oh My Posh
    $currentCheck++
    Write-Progress -Activity "Pre-flight checks" -Status "Checking Oh My Posh..." -PercentComplete ([int](($currentCheck / $totalChecks) * 100))
    
    if ($Configuration.ohMyPosh.enabled) {
        $poshInstalled = Get-Command oh-my-posh -ErrorAction SilentlyContinue
        if ($poshInstalled -and (Test-Path $PROFILE)) {
            $profileContent = Get-Content $PROFILE -Raw
            $themeName = $Configuration.ohMyPosh.theme
            $poshInitLine = "oh-my-posh init pwsh --config `"`$env:POSH_THEMES_PATH\$themeName.omp.json`" | Invoke-Expression"
            $isConfigured = $profileContent -match [regex]::Escape($poshInitLine)
            
            $status.OhMyPosh = [PSCustomObject]@{
                Installed = $true
                Configured = $isConfigured
                Theme = $themeName
                Action = if ($isConfigured) { "Skip" } else { "Configure theme" }
            }
        } else {
            $status.OhMyPosh = [PSCustomObject]@{
                Installed = ($null -ne $poshInstalled)
                Configured = $false
                Theme = $Configuration.ohMyPosh.theme
                Action = if ($poshInstalled) { "Configure theme" } else { "Will be installed & configured" }
            }
        }
    }
    
    # Check Repository
    $currentCheck++
    Write-Progress -Activity "Pre-flight checks" -Status "Checking repository..." -PercentComplete ([int](($currentCheck / $totalChecks) * 100))
    if ($Configuration.repository.owner -and $Configuration.repository.name) {
        $repoPath = [Environment]::ExpandEnvironmentVariables($Configuration.repository.clonePath)
        $repoExists = Test-Path $repoPath
        
        $status.Repository = [PSCustomObject]@{
            Path = $repoPath
            Exists = $repoExists
            Action = if ($repoExists) { "Pull updates" } else { "Clone" }
        }
    }
    
    # Check Firefox Extensions
    if ($Configuration.firefoxExtensions -and $Configuration.firefoxExtensions.Count -gt 0) {
        $currentCheck++
        Write-Progress -Activity "Pre-flight checks" -Status "Checking Firefox extensions..." -PercentComplete ([int](($currentCheck / $totalChecks) * 100))
        
        $status.FirefoxExtensions = @()
        $firefoxProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"
        $extensionsDir = $null
        
        if (Test-Path $firefoxProfiles) {
            $defaultProfile = Get-ChildItem $firefoxProfiles -Directory | Where-Object { $_.Name -match "\.default-release$" } | Select-Object -First 1
            if (-not $defaultProfile) {
                $defaultProfile = Get-ChildItem $firefoxProfiles -Directory | Select-Object -First 1
            }
            if ($defaultProfile) {
                $extensionsDir = Join-Path $defaultProfile.FullName "extensions"
            }
        }
        
        foreach ($ext in $Configuration.firefoxExtensions) {
            $isInstalled = $false
            if ($extensionsDir) {
                $extFile = Join-Path $extensionsDir "$($ext.id).xpi"
                $isInstalled = Test-Path $extFile
            }
            
            $status.FirefoxExtensions += [PSCustomObject]@{
                Name = $ext.name
                Id = $ext.id
                Url = $ext.url
                Installed = $isInstalled
            }
        }
    }
    
    Write-Progress -Activity "Pre-flight checks" -Completed
    
    return $status
}

# Function to display pre-flight status
function Show-PreFlightStatus {
    param($Status)
    
    Write-Host "`n╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    PRE-FLIGHT CHECK RESULTS                           ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan
    
    # Tools summary
    $toInstall = ($Status.Tools | Where-Object { $_.Action -eq "Install" }).Count
    $alreadyInstalled = ($Status.Tools | Where-Object { $_.Action -eq "Skip" }).Count
    
    Write-Host "📦 TOOLS SUMMARY:" -ForegroundColor Yellow
    Write-Host "   Total configured: $($Status.Tools.Count)" -ForegroundColor Gray
    Write-Host "   Already installed: $alreadyInstalled" -ForegroundColor Green
    Write-Host "   To be installed: $toInstall" -ForegroundColor Cyan
    
    if ($toInstall -gt 0) {
        Write-Host "`n   Tools to install:" -ForegroundColor Cyan
        $Status.Tools | Where-Object { $_.Action -eq "Install" } | ForEach-Object {
            Write-Host "   • $($_.Name) ($($_.Id))" -ForegroundColor White
        }
    }
    
    # GitHub CLI status
    Write-Host "`n🔧 GITHUB CLI:" -ForegroundColor Yellow
    if ($Status.GitHubCLI.Installed) {
        Write-Host "   Status: Installed" -ForegroundColor Green
        Write-Host "   Authenticated: $(if ($Status.GitHubCLI.Authenticated) { 'Yes' } else { 'No' })" -ForegroundColor $(if ($Status.GitHubCLI.Authenticated) { 'Green' } else { 'Red' })
        Write-Host "   Action: $($Status.GitHubCLI.Action)" -ForegroundColor Gray
    } else {
        Write-Host "   Status: Not installed" -ForegroundColor Red
        Write-Host "   Action: $($Status.GitHubCLI.Action)" -ForegroundColor Cyan
    }
    
    # Oh My Posh status
    if ($Status.OhMyPosh) {
        Write-Host "`n🎨 OH MY POSH:" -ForegroundColor Yellow
        Write-Host "   Installed: $(if ($Status.OhMyPosh.Installed) { 'Yes' } else { 'No' })" -ForegroundColor $(if ($Status.OhMyPosh.Installed) { 'Green' } else { 'Red' })
        Write-Host "   Configured: $(if ($Status.OhMyPosh.Configured) { 'Yes' } else { 'No' })" -ForegroundColor $(if ($Status.OhMyPosh.Configured) { 'Green' } else { 'Red' })
        Write-Host "   Theme: $($Status.OhMyPosh.Theme)" -ForegroundColor Gray
        Write-Host "   Action: $($Status.OhMyPosh.Action)" -ForegroundColor Gray
    }
    
    # Repository status
    if ($Status.Repository) {
        Write-Host "`n📁 REPOSITORY:" -ForegroundColor Yellow
        Write-Host "   Path: $($Status.Repository.Path)" -ForegroundColor Gray
        Write-Host "   Exists: $(if ($Status.Repository.Exists) { 'Yes' } else { 'No' })" -ForegroundColor $(if ($Status.Repository.Exists) { 'Green' } else { 'Red' })
        Write-Host "   Action: $($Status.Repository.Action)" -ForegroundColor Gray
    }
    
    # Firefox Extensions status
    if ($Status.FirefoxExtensions) {
        $extToInstall = ($Status.FirefoxExtensions | Where-Object { -not $_.Installed }).Count
        $extInstalled = ($Status.FirefoxExtensions | Where-Object { $_.Installed }).Count
        
        Write-Host "`n🦊 FIREFOX EXTENSIONS:" -ForegroundColor Yellow
        Write-Host "   Configured: $($Status.FirefoxExtensions.Count)" -ForegroundColor Gray
        Write-Host "   Installed: $extInstalled" -ForegroundColor Green
        Write-Host "   To install: $extToInstall" -ForegroundColor $(if ($extToInstall -gt 0) { 'Cyan' } else { 'Gray' })
        
        if ($extToInstall -gt 0) {
            $Status.FirefoxExtensions | Where-Object { -not $_.Installed } | ForEach-Object {
                Write-Host "   • $($_.Name)" -ForegroundColor White
            }
        }
    }
    
    Write-Host ""
}

# Function to verify if the WinGet executable is available in the system path
function Test-WinGet {
    try {
        # Check if the winget command exists and suppress output
        $null = Get-Command winget -ErrorAction Stop
        # Return true if found
        return $true
    }
    catch {
        # Return false if an error occurred during the check
        return $false
    }
}

# Main function to handle the installation logic
function Install-Tools {
    param(
        $Configuration,
        $PreFlightStatus,
        [bool]$IsDryRun = $false
    )
    
    # Check if WinGet is present before proceeding
    if (-not (Test-WinGet)) {
        Write-Host "Error: WinGet is not installed. Please install it from the Microsoft Store." -ForegroundColor Red
        return
    }
    
    $toolsToInstall = $PreFlightStatus.Tools | Where-Object { $_.Action -eq "Install" }
    $toolsAlreadyInstalled = $PreFlightStatus.Tools | Where-Object { $_.Action -eq "Skip" }
    
    # Output a starting message
    if ($IsDryRun) {
        Write-Host "`n=== DRY RUN MODE - No changes will be made ===" -ForegroundColor Magenta
    } else {
        Write-Host "`n=== Installing $($toolsToInstall.Count) Tools ===" -ForegroundColor Cyan
    }
    
    # Only process tools that need installing
    $installed = 0
    $failed = 0
    
    foreach ($tool in $toolsToInstall) {
        if ($IsDryRun) {
            Write-Host " • [DRY RUN] Would install $($tool.Name)" -ForegroundColor Cyan
        } else {
            Write-Host " • Installing $($tool.Name)..." -ForegroundColor Green -NoNewline
            winget install --id $tool.Id --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host " ✓" -ForegroundColor Green
                $installed++
            } else {
                Write-Host " ✗ (Exit: $LASTEXITCODE)" -ForegroundColor Red
                $failed++
            }
        }
    }
    
    if (-not $IsDryRun -and $toolsToInstall.Count -gt 0) {
        Write-Host "`n   Summary: $installed installed, $failed failed, $($toolsAlreadyInstalled.Count) already installed" -ForegroundColor Gray
    }

    # --- GitHub CLI Setup & Authentication ---
    if ($PreFlightStatus.GitHubCLI.Action -ne "Skip auth") {
        Write-Host "`n=== GitHub CLI Configuration ===" -ForegroundColor Cyan
        if ($PreFlightStatus.GitHubCLI.Installed) {
            if ($IsDryRun) {
                Write-Host " • [DRY RUN] Would authenticate with GitHub" -ForegroundColor Cyan
            } else {
                Write-Host " • Authenticating with GitHub..." -ForegroundColor Green
                gh auth login
            }
        }
    }
    
    # Install GitHub Copilot CLI extension
    if ($PreFlightStatus.GitHubCLI.Installed) {
        if ($IsDryRun) {
            Write-Host " • [DRY RUN] Would install GitHub Copilot extension" -ForegroundColor Cyan
        } else {
            gh extension install github/gh-copilot --force 2>$null
        }
    }
    
    # Clone/sync repository if configured
    if ($PreFlightStatus.Repository) {
        Write-Host "`n=== Repository Configuration ===" -ForegroundColor Cyan
        $repoPath = $PreFlightStatus.Repository.Path
        $repoFullName = "$($Configuration.repository.owner)/$($Configuration.repository.name)"
        
        if ($PreFlightStatus.Repository.Exists) {
            if ($IsDryRun) {
                Write-Host " • [DRY RUN] Would pull latest changes" -ForegroundColor Cyan
            } else {
                Write-Host " • Pulling latest changes..." -ForegroundColor Green -NoNewline
                Push-Location $repoPath
                git pull origin main 2>$null | Out-Null
                Pop-Location
                Write-Host " ✓" -ForegroundColor Green
            }
        } else {
            if ($IsDryRun) {
                Write-Host " • [DRY RUN] Would clone repository to $repoPath" -ForegroundColor Cyan
            } else {
                Write-Host " • Cloning repository..." -ForegroundColor Green -NoNewline
                gh repo clone $repoFullName $repoPath 2>$null | Out-Null
                Write-Host " ✓" -ForegroundColor Green
            }
        }
        
        # Sync script to repository
        if (-not $IsDryRun -and (Get-Command gh -ErrorAction SilentlyContinue)) {
            $authStatus = gh auth status 2>&1
            if ($authStatus -match "Logged in to github.com") {
                $scriptSource = $PSCommandPath
                $scriptDest = Join-Path $repoPath "JustHowILikeIt.ps1"
                
                if (Test-Path $scriptSource) {
                    Copy-Item -Path $scriptSource -Destination $scriptDest -Force
                }
            }
        }
    }

    # --- Oh My Posh Desired State Configuration ---
    if ($PreFlightStatus.OhMyPosh -and $PreFlightStatus.OhMyPosh.Action -ne "Skip") {
        Write-Host "`n=== Oh My Posh Configuration ===" -ForegroundColor Cyan
        if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
            $themeName = $Configuration.ohMyPosh.theme
            $poshInitLine = "oh-my-posh init pwsh --config `"`$env:POSH_THEMES_PATH\$themeName.omp.json`" | Invoke-Expression"
            
            if (-not (Test-Path $PROFILE)) {
                if ($IsDryRun) {
                    Write-Host " • [DRY RUN] Would create PowerShell profile" -ForegroundColor Cyan
                } else {
                    New-Item -Path $PROFILE -Type File -Force | Out-Null
                }
            }

            $profileContent = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { "" }
            
            if (-not ($profileContent -match [regex]::Escape($poshInitLine))) {
                if ($IsDryRun) {
                    Write-Host " • [DRY RUN] Would add $themeName theme to profile" -ForegroundColor Cyan
                } else {
                    Write-Host " • Adding $themeName theme to profile..." -ForegroundColor Green -NoNewline
                    Add-Content -Path $PROFILE -Value "`n# Oh My Posh Configuration`n$poshInitLine"
                    Write-Host " ✓" -ForegroundColor Green
                }
            }
        }
    }

    # --- Firefox Extensions ---
    if ($Configuration.firefoxExtensions -and $Configuration.firefoxExtensions.Count -gt 0) {
        Write-Host "`n=== Firefox Extensions ===" -ForegroundColor Cyan
        
        # Find Firefox profile directory
        $firefoxProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"
        if (Test-Path $firefoxProfiles) {
            $defaultProfile = Get-ChildItem $firefoxProfiles -Directory | Where-Object { $_.Name -match "\.default-release$" } | Select-Object -First 1
            
            if (-not $defaultProfile) {
                $defaultProfile = Get-ChildItem $firefoxProfiles -Directory | Select-Object -First 1
            }
            
            if ($defaultProfile) {
                $extensionsDir = Join-Path $defaultProfile.FullName "extensions"
                
                if (-not (Test-Path $extensionsDir)) {
                    if (-not $IsDryRun) {
                        New-Item -Path $extensionsDir -ItemType Directory -Force | Out-Null
                    }
                }
                
                foreach ($ext in $Configuration.firefoxExtensions) {
                    $extFile = Join-Path $extensionsDir "$($ext.id).xpi"
                    
                    if (Test-Path $extFile) {
                        Write-Host " • $($ext.name) already installed" -ForegroundColor Gray
                    } else {
                        if ($IsDryRun) {
                            Write-Host " • [DRY RUN] Would install $($ext.name)" -ForegroundColor Cyan
                        } else {
                            Write-Host " • Installing $($ext.name)..." -ForegroundColor Green -NoNewline
                            try {
                                Invoke-WebRequest -Uri $ext.url -OutFile $extFile -UseBasicParsing
                                Write-Host " ✓" -ForegroundColor Green
                            } catch {
                                Write-Host " ✗ (Download failed)" -ForegroundColor Red
                            }
                        }
                    }
                }
                
                Write-Host " ! Restart Firefox to activate extensions" -ForegroundColor Yellow
            } else {
                Write-Host " ! No Firefox profile found. Run Firefox once first." -ForegroundColor Yellow
            }
        } else {
            Write-Host " ! Firefox not configured yet. Run Firefox once first." -ForegroundColor Yellow
        }
    }

    # Final summary
    if ($IsDryRun) {
        Write-Host "`n=== DRY RUN Complete ===" -ForegroundColor Magenta
        Write-Host "No changes were made. Run without -DryRun to apply." -ForegroundColor Yellow
    } else {
        Write-Host "`n=== ✓ Setup Complete ===" -ForegroundColor Green
        if ($toolsToInstall.Count -gt 0 -or $PreFlightStatus.OhMyPosh.Action -ne "Skip") {
            Write-Host "Restart your terminal for changes to take effect." -ForegroundColor Yellow
        }
        
        # Refresh and save cache after installation
        Write-Host "`nUpdating status cache..." -ForegroundColor Gray
        $freshStatus = Get-PreFlightStatus -Configuration $Configuration
        Save-StatusToCache -Status $freshStatus
    }
}

# Check for cached pre-flight status
$preFlightStatus = $null
$usedCache = $false

if (-not $NoCache -and (Test-CacheValid)) {
    $preFlightStatus = Get-CachedStatus
    if ($preFlightStatus) {
        $cacheAge = [Math]::Round(((Get-Date) - [DateTime]::Parse($preFlightStatus.LastUpdated)).TotalMinutes)
        Write-Host "📋 Using cached status (${cacheAge}m old). Use -NoCache to refresh." -ForegroundColor Gray
        $usedCache = $true
    }
}

if (-not $preFlightStatus) {
    $preFlightStatus = Get-PreFlightStatus -Configuration $config
    Save-StatusToCache -Status $preFlightStatus
}

Show-PreFlightStatus -Status $preFlightStatus

if ($DryRun) {
    Install-Tools -Configuration $config -PreFlightStatus $preFlightStatus -IsDryRun $true
} else {
    $proceed = Read-Host "`nProceed with installation? (Y/n)"
    if ($proceed -eq "" -or $proceed -eq "Y" -or $proceed -eq "y") {
        Install-Tools -Configuration $config -PreFlightStatus $preFlightStatus -IsDryRun $false
    } else {
        Write-Host "Installation cancelled." -ForegroundColor Yellow
    }
}