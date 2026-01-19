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
$script:CacheMaxAgeMinutes = 120  # Cache valid for 2 hours

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
            NerdFont = $cache.NerdFont
            Repository = $cache.Repository
            FirefoxExtensions = @()
            DockerImages = @()
            LastUpdated = $cache.LastUpdated
        }
        
        foreach ($tool in $cache.Tools) {
            $status.Tools += [PSCustomObject]@{
                Name = $tool.Name
                Id = $tool.Id
                Category = $tool.Category
                Version = $tool.Version
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
        
        if ($cache.DockerImages) {
            foreach ($img in $cache.DockerImages) {
                $status.DockerImages += [PSCustomObject]@{
                    Name = $img.Name
                    Image = $img.Image
                    Tag = $img.Tag
                    FullImage = $img.FullImage
                    Installed = $img.Installed
                    Action = $img.Action
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
        NerdFont = $Status.NerdFont
        Repository = $Status.Repository
        FirefoxExtensions = $Status.FirefoxExtensions
        DockerImages = $Status.DockerImages
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
        # Try with --exact first, then fall back to partial match
        $checkInstalled = winget list --id $ToolId --exact 2>$null | Out-String
        if ($checkInstalled -match [regex]::Escape($ToolId)) {
            return $true
        }
        # Fallback: check without --exact for packages that may have different source tracking
        $checkInstalled = winget list $ToolId 2>$null | Out-String
        return ($checkInstalled -match [regex]::Escape($ToolId))
    }
    catch {
        return $false
    }
}

# Function to perform pre-flight checks with progress bar
function Get-PreFlightStatus {
    param(
        $Configuration,
        [switch]$Silent
    )
    
    $status = @{
        Tools = @()
        GitHubCLI = $null
        OhMyPosh = $null
        NerdFont = $null
        Repository = $null
        FirefoxExtensions = @()
        DockerImages = @()
    }
    
    if (-not $Silent) {
        Write-Host "`n🔍 Running pre-flight checks..." -ForegroundColor Cyan
    }
    
    $firefoxExtCount = if ($Configuration.firefoxExtensions) { 1 } else { 0 }
    $fontCheck = if ($Configuration.ohMyPosh.font) { 1 } else { 0 }
    $dockerCheck = if ($Configuration.dockerImages) { 1 } else { 0 }
    $totalChecks = $Configuration.tools.Count + 3 + $firefoxExtCount + $fontCheck + $dockerCheck  # tools + gh + posh + repo + firefox + font + docker
    $currentCheck = 0
    
    # Check each tool with progress bar
    foreach ($tool in $Configuration.tools) {
        $currentCheck++
        $percentComplete = [int](($currentCheck / $totalChecks) * 100)
        Write-Progress -Activity "Pre-flight checks" -Status "Checking $($tool.name)..." -PercentComplete $percentComplete
        
        $isInstalled = Test-ToolInstalled -ToolId $tool.id
        $version = if ($tool.version) { $tool.version } else { $null }
        $action = if ($isInstalled) { 
            if ($version) { "Skip (pinned to $version)" } else { "Skip" }
        } else { 
            if ($version) { "Install v$version" } else { "Install" }
        }
        
        $status.Tools += [PSCustomObject]@{
            Name = $tool.name
            Id = $tool.id
            Category = $tool.category
            Version = $version
            Installed = $isInstalled
            Action = $action
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
        
        # Check Nerd Font
        $fontName = $Configuration.ohMyPosh.font
        if ($fontName) {
            $currentCheck++
            Write-Progress -Activity "Pre-flight checks" -Status "Checking Nerd Font..." -PercentComplete ([int](($currentCheck / $totalChecks) * 100))
            
            # Check user fonts folder
            $userFontsPath = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
            $fontInstalled = $false
            if (Test-Path $userFontsPath) {
                $fontInstalled = (Get-ChildItem $userFontsPath -Filter "*$fontName*" -ErrorAction SilentlyContinue).Count -gt 0
            }
            # Also check system fonts
            if (-not $fontInstalled) {
                $fontInstalled = (Get-ChildItem "C:\Windows\Fonts" -Filter "*$fontName*" -ErrorAction SilentlyContinue).Count -gt 0
            }
            # Also check via .NET InstalledFontCollection
            if (-not $fontInstalled) {
                try {
                    Add-Type -AssemblyName System.Drawing
                    $fonts = (New-Object System.Drawing.Text.InstalledFontCollection).Families
                    $fontInstalled = ($fonts | Where-Object { $_.Name -match $fontName }).Count -gt 0
                } catch {}
            }
            # Also check if VS Code is already configured with this font (means it was installed)
            if (-not $fontInstalled) {
                $vscodeSettingsPath = "$env:APPDATA\Code\User\settings.json"
                if (Test-Path $vscodeSettingsPath) {
                    try {
                        $vscodeSettings = Get-Content $vscodeSettingsPath -Raw | ConvertFrom-Json
                        $terminalFont = $vscodeSettings.'terminal.integrated.fontFamily'
                        if ($terminalFont -match $fontName) {
                            $fontInstalled = $true
                        }
                    } catch {}
                }
            }
            
            $status.NerdFont = [PSCustomObject]@{
                Name = $fontName
                Installed = $fontInstalled
                Action = if ($fontInstalled) { "Skip" } else { "Install font" }
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
    
    # Check Docker Images
    if ($Configuration.dockerImages -and $Configuration.dockerImages.Count -gt 0) {
        $currentCheck++
        Write-Progress -Activity "Pre-flight checks" -Status "Checking Docker images..." -PercentComplete ([int](($currentCheck / $totalChecks) * 100))
        
        $dockerAvailable = Get-Command docker -ErrorAction SilentlyContinue
        if ($dockerAvailable) {
            $existingImages = docker images --format "{{.Repository}}:{{.Tag}}" 2>$null
            
            foreach ($img in $Configuration.dockerImages) {
                $tag = if ($img.tag) { $img.tag } else { "latest" }
                $fullImage = "$($img.image):$tag"
                $isPresent = $existingImages -contains $fullImage
                
                $status.DockerImages += [PSCustomObject]@{
                    Name = $img.name
                    Image = $img.image
                    Tag = $tag
                    FullImage = $fullImage
                    Installed = $isPresent
                    Action = if ($isPresent) { "Skip" } else { "Pull" }
                }
            }
        } else {
            foreach ($img in $Configuration.dockerImages) {
                $tag = if ($img.tag) { $img.tag } else { "latest" }
                $status.DockerImages += [PSCustomObject]@{
                    Name = $img.name
                    Image = $img.image
                    Tag = $tag
                    FullImage = "$($img.image):$tag"
                    Installed = $false
                    Action = "Docker not available"
                }
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
    Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    # Tools summary
    $toInstall = ($Status.Tools | Where-Object { $_.Action -eq "Install" }).Count
    $alreadyInstalled = ($Status.Tools | Where-Object { $_.Action -eq "Skip" -or $_.Action -match "^Skip" }).Count
    $toolsColor = if ($toInstall -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "📦 Tools: $alreadyInstalled/$($Status.Tools.Count) installed" -ForegroundColor $toolsColor -NoNewline
    if ($toInstall -gt 0) {
        $toolNames = ($Status.Tools | Where-Object { $_.Action -eq "Install" } | ForEach-Object { $_.Name }) -join ", "
        Write-Host " (to install: $toolNames)" -ForegroundColor Cyan
    } else {
        Write-Host ""
    }
    
    # GitHub CLI status - one line
    $ghStatus = if ($Status.GitHubCLI.Installed -and $Status.GitHubCLI.Authenticated) { "✓ Authenticated" } 
                elseif ($Status.GitHubCLI.Installed) { "⚠ Not authenticated" } 
                else { "✗ Not installed" }
    $ghColor = if ($Status.GitHubCLI.Installed -and $Status.GitHubCLI.Authenticated) { 'Green' } 
               elseif ($Status.GitHubCLI.Installed) { 'Yellow' } 
               else { 'Red' }
    Write-Host "🔧 GitHub CLI: $ghStatus" -ForegroundColor $ghColor
    
    # Oh My Posh status - one line
    if ($Status.OhMyPosh) {
        $poshStatus = if ($Status.OhMyPosh.Installed -and $Status.OhMyPosh.Configured) { "✓ $($Status.OhMyPosh.Theme) theme" }
                      elseif ($Status.OhMyPosh.Installed) { "⚠ Needs config" }
                      else { "✗ Not installed" }
        $poshColor = if ($Status.OhMyPosh.Installed -and $Status.OhMyPosh.Configured) { 'Green' } 
                     elseif ($Status.OhMyPosh.Installed) { 'Yellow' } 
                     else { 'Red' }
        Write-Host "🎨 Oh My Posh: $poshStatus" -ForegroundColor $poshColor
    }
    
    # Nerd Font status - one line
    if ($Status.NerdFont) {
        $fontStatus = if ($Status.NerdFont.Installed) { "✓ $($Status.NerdFont.Name)" } else { "✗ $($Status.NerdFont.Name) needs install" }
        $fontColor = if ($Status.NerdFont.Installed) { 'Green' } else { 'Yellow' }
        Write-Host "🔤 Nerd Font: $fontStatus" -ForegroundColor $fontColor
    }
    
    # Repository status - one line
    if ($Status.Repository) {
        $repoStatus = if ($Status.Repository.Exists) { "✓ $($Status.Repository.Path)" } else { "✗ Needs clone" }
        $repoColor = if ($Status.Repository.Exists) { 'Green' } else { 'Yellow' }
        Write-Host "📁 Repository: $repoStatus" -ForegroundColor $repoColor
    }
    
    # Firefox Extensions status - one line
    if ($Status.FirefoxExtensions) {
        $extToInstall = ($Status.FirefoxExtensions | Where-Object { -not $_.Installed }).Count
        $extInstalled = ($Status.FirefoxExtensions | Where-Object { $_.Installed }).Count
        $extColor = if ($extToInstall -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host "🦊 Firefox Extensions: $extInstalled/$($Status.FirefoxExtensions.Count) installed" -ForegroundColor $extColor -NoNewline
        if ($extToInstall -gt 0) {
            $extNames = ($Status.FirefoxExtensions | Where-Object { -not $_.Installed } | ForEach-Object { $_.Name }) -join ", "
            Write-Host " (to install: $extNames)" -ForegroundColor Cyan
        } else {
            Write-Host ""
        }
    }
    
    # Docker Images status - one line
    if ($Status.DockerImages -and $Status.DockerImages.Count -gt 0) {
        $imgToPull = ($Status.DockerImages | Where-Object { -not $_.Installed }).Count
        $imgInstalled = ($Status.DockerImages | Where-Object { $_.Installed }).Count
        $imgColor = if ($imgToPull -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host "🐳 Docker Images: $imgInstalled/$($Status.DockerImages.Count) present" -ForegroundColor $imgColor -NoNewline
        if ($imgToPull -gt 0) {
            $imgNames = ($Status.DockerImages | Where-Object { -not $_.Installed } | ForEach-Object { $_.Name }) -join ", "
            Write-Host " (to pull: $imgNames)" -ForegroundColor Cyan
        } else {
            Write-Host ""
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
            $versionInfo = if ($tool.Version) { " v$($tool.Version)" } else { "" }
            Write-Host " • [DRY RUN] Would install $($tool.Name)$versionInfo" -ForegroundColor Cyan
        } else {
            $versionInfo = if ($tool.Version) { " v$($tool.Version)" } else { "" }
            Write-Host " • Installing $($tool.Name)$versionInfo..." -ForegroundColor Green -NoNewline
            
            $wingetArgs = @("install", "--id", $tool.Id, "--silent", "--accept-package-agreements", "--accept-source-agreements")
            if ($tool.Version) {
                $wingetArgs += @("--version", $tool.Version)
            }
            
            & winget @wingetArgs 2>&1 | Out-Null
            
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

    # --- Nerd Font Installation ---
    if ($PreFlightStatus.NerdFont -and $PreFlightStatus.NerdFont.Action -ne "Skip") {
        Write-Host "`n=== Nerd Font Installation ===" -ForegroundColor Cyan
        $fontName = $Configuration.ohMyPosh.font
        if ($fontName) {
            if ($IsDryRun) {
                Write-Host " • [DRY RUN] Would install $fontName Nerd Font" -ForegroundColor Cyan
            } else {
                Write-Host " • Installing $fontName Nerd Font..." -ForegroundColor Green -NoNewline
                try {
                    $result = & oh-my-posh font install $fontName --headless 2>&1
                    Write-Host " ✓" -ForegroundColor Green
                }
                catch {
                    Write-Host " ✗" -ForegroundColor Red
                    Write-Host "   Error: $_" -ForegroundColor Red
                }
            }
            
            # Configure VS Code terminal font
            $vscodeSettingsPath = "$env:APPDATA\Code\User\settings.json"
            if (Test-Path $vscodeSettingsPath) {
                $vscodeSettings = Get-Content $vscodeSettingsPath -Raw | ConvertFrom-Json
                $fontFamily = "$fontName Nerd Font"
                $currentFont = $vscodeSettings.'terminal.integrated.fontFamily'
                
                if ($currentFont -ne $fontFamily) {
                    if ($IsDryRun) {
                        Write-Host " • [DRY RUN] Would set VS Code terminal font to '$fontFamily'" -ForegroundColor Cyan
                    } else {
                        Write-Host " • Setting VS Code terminal font..." -ForegroundColor Green -NoNewline
                        $vscodeSettings | Add-Member -NotePropertyName 'terminal.integrated.fontFamily' -NotePropertyValue $fontFamily -Force
                        $vscodeSettings | ConvertTo-Json -Depth 10 | Set-Content $vscodeSettingsPath -Encoding UTF8
                        Write-Host " ✓" -ForegroundColor Green
                    }
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

    # --- Docker Images ---
    if ($Configuration.dockerImages -and $Configuration.dockerImages.Count -gt 0) {
        Write-Host "`n=== Docker Images ===" -ForegroundColor Cyan
        
        $dockerAvailable = Get-Command docker -ErrorAction SilentlyContinue
        if ($dockerAvailable) {
            foreach ($img in $Configuration.dockerImages) {
                $tag = if ($img.tag) { $img.tag } else { "latest" }
                $fullImage = "$($img.image):$tag"
                
                $imgStatus = $PreFlightStatus.DockerImages | Where-Object { $_.FullImage -eq $fullImage }
                
                if ($imgStatus -and $imgStatus.Installed) {
                    Write-Host " • $($img.name) already present" -ForegroundColor Gray
                } else {
                    if ($IsDryRun) {
                        Write-Host " • [DRY RUN] Would pull $fullImage" -ForegroundColor Cyan
                    } else {
                        Write-Host " • Pulling $($img.name) ($fullImage)..." -ForegroundColor Green
                        $pullResult = docker pull $fullImage 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "   ✓ Pulled successfully" -ForegroundColor Green
                        } else {
                            Write-Host "   ✗ Pull failed" -ForegroundColor Red
                        }
                    }
                }
            }
        } else {
            Write-Host " ! Docker is not available. Install Docker Desktop first." -ForegroundColor Yellow
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
        
        # Update cache incrementally - just mark installed items as done
        # Update tools that were just installed
        foreach ($tool in $toolsToInstall) {
            $cachedTool = $PreFlightStatus.Tools | Where-Object { $_.Id -eq $tool.Id }
            if ($cachedTool) {
                $cachedTool.Installed = $true
                $cachedTool.Action = "Skip"
            }
        }
        # Update Nerd Font if it was installed
        if ($PreFlightStatus.NerdFont -and $PreFlightStatus.NerdFont.Action -ne "Skip") {
            $PreFlightStatus.NerdFont.Installed = $true
            $PreFlightStatus.NerdFont.Action = "Skip"
        }
        # Update Docker images that were pulled
        if ($PreFlightStatus.DockerImages) {
            foreach ($img in $PreFlightStatus.DockerImages) {
                if ($img.Action -eq "Pull") {
                    $img.Installed = $true
                    $img.Action = "Skip"
                }
            }
        }
        Save-StatusToCache -Status $PreFlightStatus
    }
}

# Check for cached pre-flight status
$preFlightStatus = $null
$usedCache = $false

if (-not $NoCache -and (Test-CacheValid)) {
    $preFlightStatus = Get-CachedStatus
    if ($preFlightStatus) {
        $cacheAge = [Math]::Round(((Get-Date) - [DateTime]::Parse($preFlightStatus.LastUpdated)).TotalMinutes)
        
        # Check for new items in config that aren't in cache
        $newTools = @()
        foreach ($tool in $config.tools) {
            $cached = $preFlightStatus.Tools | Where-Object { $_.Id -eq $tool.id }
            if (-not $cached) {
                # New tool - check if installed
                Write-Host "🔍 Checking new tool: $($tool.name)..." -ForegroundColor Cyan -NoNewline
                $isInstalled = Test-ToolInstalled -ToolId $tool.id
                $version = if ($tool.version) { $tool.version } else { $null }
                $action = if ($isInstalled) { "Skip" } else { "Install" }
                $preFlightStatus.Tools += [PSCustomObject]@{
                    Name = $tool.name
                    Id = $tool.id
                    Category = $tool.category
                    Version = $version
                    Installed = $isInstalled
                    Action = $action
                }
                Write-Host $(if ($isInstalled) { " ✓ installed" } else { " needs install" }) -ForegroundColor $(if ($isInstalled) { 'Green' } else { 'Yellow' })
                $newTools += $tool.name
            }
        }
        
        # Check for new Docker images
        if ($config.dockerImages) {
            foreach ($img in $config.dockerImages) {
                $tag = if ($img.tag) { $img.tag } else { "latest" }
                $fullImage = "$($img.image):$tag"
                $cached = $preFlightStatus.DockerImages | Where-Object { $_.FullImage -eq $fullImage }
                if (-not $cached) {
                    Write-Host "🔍 Checking new Docker image: $($img.name)..." -ForegroundColor Cyan -NoNewline
                    $dockerAvailable = Get-Command docker -ErrorAction SilentlyContinue
                    $isPresent = $false
                    if ($dockerAvailable) {
                        $existingImages = docker images --format "{{.Repository}}:{{.Tag}}" 2>$null
                        $isPresent = $existingImages -contains $fullImage
                    }
                    $preFlightStatus.DockerImages += [PSCustomObject]@{
                        Name = $img.name
                        Image = $img.image
                        Tag = $tag
                        FullImage = $fullImage
                        Installed = $isPresent
                        Action = if ($isPresent) { "Skip" } else { "Pull" }
                    }
                    Write-Host $(if ($isPresent) { " ✓ present" } else { " needs pull" }) -ForegroundColor $(if ($isPresent) { 'Green' } else { 'Yellow' })
                }
            }
        }
        
        if ($newTools.Count -gt 0) {
            Save-StatusToCache -Status $preFlightStatus
        }
        
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
    Install-Tools -Configuration $config -PreFlightStatus $preFlightStatus -IsDryRun $false
}