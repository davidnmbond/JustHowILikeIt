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
            DotnetTools = @()
            Backups = @()
            WindowsSettings = $cache.WindowsSettings
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
        DotnetTools = $Status.DotnetTools
        WindowsSettings = $Status.WindowsSettings
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
        Backups = @()
        WindowsSettings = $null
    }
    
    if (-not $Silent) {
        Write-Host "`n🔍 Running pre-flight checks..." -ForegroundColor Cyan
    }
    
    $firefoxExtCount = if ($Configuration.firefoxExtensions) { 1 } else { 0 }
    $fontCheck = if ($Configuration.fonts.nerdFont -or $Configuration.ohMyPosh.font) { 1 } else { 0 }
    $dockerCheck = if ($Configuration.dockerImages) { 1 } else { 0 }
    $backupCheck = if ($Configuration.backups) { 1 } else { 0 }
    $windowsSettingsCheck = if ($Configuration.windowsSettings) { 1 } else { 0 }
    $totalChecks = $Configuration.tools.Count + 3 + $firefoxExtCount + $fontCheck + $dockerCheck + $backupCheck + $windowsSettingsCheck
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
        
        # Check Nerd Font (now from fonts config section)
        $fontName = if ($Configuration.fonts.nerdFont) { $Configuration.fonts.nerdFont } else { $Configuration.ohMyPosh.font }
        $terminalFontName = if ($Configuration.fonts.terminalFontName) { $Configuration.fonts.terminalFontName } else { "$fontName NF" }
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
                    $fontInstalled = ($fonts | Where-Object { $_.Name -match $fontName -or $_.Name -eq $terminalFontName }).Count -gt 0
                } catch {}
            }
            # Also check if Windows Terminal is already configured with this font
            if (-not $fontInstalled) {
                $wtSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
                if (Test-Path $wtSettingsPath) {
                    try {
                        $wtSettings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
                        $wtFont = $wtSettings.profiles.defaults.font.face
                        if ($wtFont -eq $terminalFontName) {
                            $fontInstalled = $true
                        }
                    } catch {}
                }
            }
            # Also check if VS Code is already configured with this font (means it was installed)
            if (-not $fontInstalled) {
                $vscodeSettingsPath = "$env:APPDATA\Code\User\settings.json"
                if (Test-Path $vscodeSettingsPath) {
                    try {
                        $vscodeSettings = Get-Content $vscodeSettingsPath -Raw | ConvertFrom-Json
                        $terminalFont = $vscodeSettings.'terminal.integrated.fontFamily'
                        if ($terminalFont -match $fontName -or $terminalFont -eq $terminalFontName) {
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
    
    # Check Dotnet Tools
    if ($Configuration.dotnetTools -and $Configuration.dotnetTools.Count -gt 0) {
        $currentCheck++
        Write-Progress -Activity "Pre-flight checks" -Status "Checking dotnet tools..." -PercentComplete ([int](($currentCheck / $totalChecks) * 100))
        
        $dotnetAvailable = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($dotnetAvailable) {
            $installedTools = dotnet tool list --global 2>$null | Select-Object -Skip 2 | ForEach-Object { ($_ -split '\s+')[0].ToLower() }
            
            foreach ($tool in $Configuration.dotnetTools) {
                $isInstalled = $installedTools -contains $tool.id.ToLower()
                
                $status.DotnetTools += [PSCustomObject]@{
                    Name = $tool.name
                    Id = $tool.id
                    Installed = $isInstalled
                    Action = if ($isInstalled) { "Skip" } else { "Install" }
                }
            }
        } else {
            foreach ($tool in $Configuration.dotnetTools) {
                $status.DotnetTools += [PSCustomObject]@{
                    Name = $tool.name
                    Id = $tool.id
                    Installed = $false
                    Action = "Dotnet not available"
                }
            }
        }
    }
    
    # Check Backup configuration
    $currentCheck++
    Write-Progress -Activity "Pre-flight checks" -Status "Checking backup configuration..." -PercentComplete ([int](($currentCheck / $totalChecks) * 100))
    
    if ($Configuration.backups -and $Configuration.backups.Count -gt 0) {
        foreach ($backup in $Configuration.backups) {
            if (-not $backup.enabled) {
                $status.Backups += [PSCustomObject]@{
                    Type = if ($backup.type) { $backup.type } else { "FileHistory" }
                    Destination = $backup.destinationPath
                    Configured = $false
                    Action = "Disabled"
                }
                continue
            }
            
            $backupType = if ($backup.type) { $backup.type } else { "FileHistory" }
            $isConfigured = $false
            
            if ($backupType -eq "FileHistory") {
                try {
                    $fhConfig = Get-CimInstance -Namespace root/Microsoft/Windows/FileHistory -ClassName MSFT_FhConfigInfo -ErrorAction Stop
                    $isConfigured = ($fhConfig.BackupLocation -eq $backup.destinationPath -and $fhConfig.Enabled)
                } catch {
                    # Fallback: check if FileHistory config folder exists in the destination
                    $fhConfigPath = Join-Path $backup.destinationPath "Configuration"
                    $isConfigured = (Test-Path $fhConfigPath)
                }
            } elseif ($backupType -eq "BitLockerKeys") {
                # Check if we have a backup from today
                if (Test-Path $backup.destinationPath) {
                    $todayFiles = Get-ChildItem -Path $backup.destinationPath -Filter "BitLocker-$env:COMPUTERNAME-*-$(Get-Date -Format 'yyyy-MM-dd').txt" -ErrorAction SilentlyContinue
                    $isConfigured = ($todayFiles.Count -gt 0)
                }
            } elseif ($backupType -eq "WindowsBackup") {
                # Check if Windows Backup is enabled via registry
                try {
                    $wbReg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppListBackup" -ErrorAction Stop
                    $isConfigured = ($wbReg.IsBackupEnabledAndMSAAttached -eq 1)
                } catch {
                    $isConfigured = $false
                }
            }
            
            $status.Backups += [PSCustomObject]@{
                Type = $backupType
                Destination = $backup.destinationPath
                Configured = $isConfigured
                Action = if ($isConfigured) { "Skip" } else { "Configure" }
            }
        }
    }
    
    # Check Windows Settings (File Explorer preferences)
    if ($Configuration.windowsSettings) {
        $currentCheck++
        Write-Progress -Activity "Pre-flight checks" -Status "Checking Windows settings..." -PercentComplete ([int][Math]::Min(($currentCheck / $totalChecks) * 100, 100))
        
        $wsStatus = @{}
        
        # Check file extensions visibility
        if ($null -ne $Configuration.windowsSettings.showFileExtensions) {
            try {
                $hideExt = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -ErrorAction Stop
                $currentlyShowing = ($hideExt.HideFileExt -eq 0)
                $wsStatus.ShowFileExtensions = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.showFileExtensions
                    Current = $currentlyShowing
                    Configured = ($currentlyShowing -eq $Configuration.windowsSettings.showFileExtensions)
                }
            } catch {
                $wsStatus.ShowFileExtensions = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.showFileExtensions
                    Current = $null
                    Configured = $false
                }
            }
        }
        
        # Check hidden files visibility
        if ($null -ne $Configuration.windowsSettings.showHiddenFiles) {
            try {
                $hidden = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -ErrorAction Stop
                $currentlyShowing = ($hidden.Hidden -eq 1)
                $wsStatus.ShowHiddenFiles = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.showHiddenFiles
                    Current = $currentlyShowing
                    Configured = ($currentlyShowing -eq $Configuration.windowsSettings.showHiddenFiles)
                }
            } catch {
                $wsStatus.ShowHiddenFiles = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.showHiddenFiles
                    Current = $null
                    Configured = $false
                }
            }
        }
        
        # Check dark mode
        if ($null -ne $Configuration.windowsSettings.darkMode) {
            try {
                $theme = Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction Stop
                $currentDarkMode = ($theme.AppsUseLightTheme -eq 0 -and $theme.SystemUsesLightTheme -eq 0)
                $wsStatus.DarkMode = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.darkMode
                    Current = $currentDarkMode
                    Configured = ($currentDarkMode -eq $Configuration.windowsSettings.darkMode)
                }
            } catch {
                $wsStatus.DarkMode = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.darkMode
                    Current = $null
                    Configured = $false
                }
            }
        }
        
        # Check desktop wallpaper
        if ($Configuration.windowsSettings.desktopWallpaper) {
            try {
                $currentWallpaper = (Get-ItemProperty "HKCU:\Control Panel\Desktop" -Name Wallpaper -ErrorAction Stop).Wallpaper
                $desiredWallpaper = $Configuration.windowsSettings.desktopWallpaper
                $wsStatus.DesktopWallpaper = [PSCustomObject]@{
                    Desired = $desiredWallpaper
                    Current = $currentWallpaper
                    Configured = ($currentWallpaper -eq $desiredWallpaper)
                }
            } catch {
                $wsStatus.DesktopWallpaper = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.desktopWallpaper
                    Current = $null
                    Configured = $false
                }
            }
        }
        
        # Check taskbar settings
        if ($Configuration.windowsSettings.taskbar) {
            $taskbarStatus = @{}
            $advancedReg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -ErrorAction SilentlyContinue
            $searchReg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -ErrorAction SilentlyContinue
            
            # Taskbar alignment (left=0, center=1)
            if ($null -ne $Configuration.windowsSettings.taskbar.alignment) {
                $desiredAlign = if ($Configuration.windowsSettings.taskbar.alignment -eq "left") { 0 } else { 1 }
                $currentAlign = $advancedReg.TaskbarAl
                $taskbarStatus.Alignment = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.taskbar.alignment
                    Current = if ($currentAlign -eq 0) { "left" } else { "center" }
                    Configured = ($currentAlign -eq $desiredAlign)
                }
            }
            
            # Widgets (show=1, hide=0)
            if ($null -ne $Configuration.windowsSettings.taskbar.showWidgets) {
                $desiredWidgets = if ($Configuration.windowsSettings.taskbar.showWidgets) { 1 } else { 0 }
                $currentWidgets = $advancedReg.TaskbarDa
                $taskbarStatus.ShowWidgets = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.taskbar.showWidgets
                    Current = ($currentWidgets -eq 1)
                    Configured = ($currentWidgets -eq $desiredWidgets)
                }
            }
            
            # Search (hidden=0, icon=1, box=2)
            if ($null -ne $Configuration.windowsSettings.taskbar.showSearch) {
                $desiredSearch = if ($Configuration.windowsSettings.taskbar.showSearch) { 1 } else { 0 }
                $currentSearch = $searchReg.SearchboxTaskbarMode
                $taskbarStatus.ShowSearch = [PSCustomObject]@{
                    Desired = $Configuration.windowsSettings.taskbar.showSearch
                    Current = ($currentSearch -gt 0)
                    Configured = (($currentSearch -gt 0) -eq $Configuration.windowsSettings.taskbar.showSearch)
                }
            }
            
            $wsStatus.Taskbar = $taskbarStatus
        }
        
        $status.WindowsSettings = $wsStatus
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
    
    # Dotnet Tools status - one line
    if ($Status.DotnetTools -and $Status.DotnetTools.Count -gt 0) {
        $toolsToInstall = ($Status.DotnetTools | Where-Object { -not $_.Installed }).Count
        $toolsInstalled = ($Status.DotnetTools | Where-Object { $_.Installed }).Count
        $toolsColor = if ($toolsToInstall -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host "🔧 Dotnet Tools: $toolsInstalled/$($Status.DotnetTools.Count) installed" -ForegroundColor $toolsColor -NoNewline
        if ($toolsToInstall -gt 0) {
            $toolNames = ($Status.DotnetTools | Where-Object { -not $_.Installed } | ForEach-Object { $_.Name }) -join ", "
            Write-Host " (to install: $toolNames)" -ForegroundColor Cyan
        } else {
            Write-Host ""
        }
    }
    
    # Backup status - one line
    if ($Status.Backups -and $Status.Backups.Count -gt 0) {
        $backupsToConfig = ($Status.Backups | Where-Object { $_.Action -eq "Configure" }).Count
        $backupsConfigured = ($Status.Backups | Where-Object { $_.Configured }).Count
        $backupsDisabled = ($Status.Backups | Where-Object { $_.Action -eq "Disabled" }).Count
        $backupColor = if ($backupsToConfig -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host "💾 Backups: $backupsConfigured/$($Status.Backups.Count - $backupsDisabled) configured" -ForegroundColor $backupColor -NoNewline
        if ($backupsDisabled -gt 0) {
            Write-Host " ($backupsDisabled disabled)" -ForegroundColor Gray -NoNewline
        }
        if ($backupsToConfig -gt 0) {
            Write-Host " (to configure: $backupsToConfig)" -ForegroundColor Cyan
        } else {
            Write-Host ""
        }
    }
    
    # Windows Settings status - one line
    if ($Status.WindowsSettings) {
        $settingsToFix = 0
        $settingsOk = 0
        $details = @()
        
        if ($Status.WindowsSettings.ShowFileExtensions) {
            if ($Status.WindowsSettings.ShowFileExtensions.Configured) { $settingsOk++ } 
            else { $settingsToFix++; $details += "file extensions" }
        }
        if ($Status.WindowsSettings.ShowHiddenFiles) {
            if ($Status.WindowsSettings.ShowHiddenFiles.Configured) { $settingsOk++ } 
            else { $settingsToFix++; $details += "hidden files" }
        }
        if ($Status.WindowsSettings.DarkMode) {
            if ($Status.WindowsSettings.DarkMode.Configured) { $settingsOk++ } 
            else { $settingsToFix++; $details += "dark mode" }
        }
        if ($Status.WindowsSettings.DesktopWallpaper) {
            if ($Status.WindowsSettings.DesktopWallpaper.Configured) { $settingsOk++ } 
            else { $settingsToFix++; $details += "wallpaper" }
        }
        if ($Status.WindowsSettings.Taskbar) {
            if ($Status.WindowsSettings.Taskbar.Alignment) {
                if ($Status.WindowsSettings.Taskbar.Alignment.Configured) { $settingsOk++ } 
                else { $settingsToFix++; $details += "taskbar alignment" }
            }
            if ($Status.WindowsSettings.Taskbar.ShowWidgets) {
                if ($Status.WindowsSettings.Taskbar.ShowWidgets.Configured) { $settingsOk++ } 
                else { $settingsToFix++; $details += "widgets" }
            }
            if ($Status.WindowsSettings.Taskbar.ShowSearch) {
                if ($Status.WindowsSettings.Taskbar.ShowSearch.Configured) { $settingsOk++ } 
                else { $settingsToFix++; $details += "search" }
            }
        }
        
        $total = $settingsOk + $settingsToFix
        if ($total -gt 0) {
            $wsColor = if ($settingsToFix -gt 0) { 'Yellow' } else { 'Green' }
            Write-Host "⚙️ Windows Settings: $settingsOk/$total configured" -ForegroundColor $wsColor -NoNewline
            if ($settingsToFix -gt 0) {
                Write-Host " (to fix: $($details -join ', '))" -ForegroundColor Cyan
            } else {
                Write-Host ""
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
            
            # Check if any oh-my-posh init line exists
            $hasOhMyPosh = $profileContent -match 'oh-my-posh init pwsh'
            $hasCorrectLine = $profileContent -match [regex]::Escape($poshInitLine)
            
            if (-not $hasCorrectLine) {
                if ($IsDryRun) {
                    Write-Host " • [DRY RUN] Would configure $themeName theme in profile" -ForegroundColor Cyan
                } else {
                    Write-Host " • Adding $themeName theme to profile..." -ForegroundColor Green -NoNewline
                    if ($hasOhMyPosh) {
                        # Replace existing oh-my-posh lines and associated comments with the correct one
                        $newContent = $profileContent -replace '(?m)^#\s*Oh My Posh.*$\r?\n?', ''
                        $newContent = $newContent -replace '(?m)^.*oh-my-posh init pwsh.*$\r?\n?', ''
                        $newContent = $newContent.Trim()
                        if ($newContent) {
                            $newContent = "$newContent`n`n# Oh My Posh Configuration`n$poshInitLine"
                        } else {
                            $newContent = "# Oh My Posh Configuration`n$poshInitLine"
                        }
                        Set-Content -Path $PROFILE -Value $newContent -Force
                    } else {
                        Add-Content -Path $PROFILE -Value "`n# Oh My Posh Configuration`n$poshInitLine"
                    }
                    Write-Host " ✓" -ForegroundColor Green
                }
            }
        }
    }

    # --- Nerd Font Installation ---
    if ($PreFlightStatus.NerdFont -and $PreFlightStatus.NerdFont.Action -ne "Skip") {
        Write-Host "`n=== Nerd Font Installation ===" -ForegroundColor Cyan
        $fontName = $Configuration.fonts.nerdFont
        $terminalFontName = if ($Configuration.fonts.terminalFontName) { $Configuration.fonts.terminalFontName } else { "$fontName NF" }
        if ($fontName) {
            if ($IsDryRun) {
                Write-Host " • [DRY RUN] Would install $fontName Nerd Font" -ForegroundColor Cyan
            } else {
                Write-Host " • Installing $fontName Nerd Font..." -ForegroundColor Green -NoNewline
                try {
                    $result = & oh-my-posh font install $fontName 2>&1
                    Write-Host " ✓" -ForegroundColor Green
                }
                catch {
                    Write-Host " ✗" -ForegroundColor Red
                    Write-Host "   Error: $_" -ForegroundColor Red
                }
            }
            
            # Configure VS Code terminal font
            if ($Configuration.fonts.configureVSCode -ne $false) {
                $vscodeSettingsPath = "$env:APPDATA\Code\User\settings.json"
                if (Test-Path $vscodeSettingsPath) {
                    $vscodeSettings = Get-Content $vscodeSettingsPath -Raw | ConvertFrom-Json
                    $currentFont = $vscodeSettings.'terminal.integrated.fontFamily'
                    
                    if ($currentFont -ne $terminalFontName) {
                        if ($IsDryRun) {
                            Write-Host " • [DRY RUN] Would set VS Code terminal font to '$terminalFontName'" -ForegroundColor Cyan
                        } else {
                            Write-Host " • Setting VS Code terminal font..." -ForegroundColor Green -NoNewline
                            $vscodeSettings | Add-Member -NotePropertyName 'terminal.integrated.fontFamily' -NotePropertyValue $terminalFontName -Force
                            $vscodeSettings | ConvertTo-Json -Depth 10 | Set-Content $vscodeSettingsPath -Encoding UTF8
                            Write-Host " ✓" -ForegroundColor Green
                        }
                    }
                }
            }
            
            # Configure Windows Terminal font
            if ($Configuration.fonts.configureWindowsTerminal -ne $false) {
                $wtSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
                if (Test-Path $wtSettingsPath) {
                    try {
                        $wtSettings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
                        $currentWtFont = $wtSettings.profiles.defaults.font.face
                        
                        if ($currentWtFont -ne $terminalFontName) {
                            if ($IsDryRun) {
                                Write-Host " • [DRY RUN] Would set Windows Terminal font to '$terminalFontName'" -ForegroundColor Cyan
                            } else {
                                Write-Host " • Setting Windows Terminal font..." -ForegroundColor Green -NoNewline
                                if (-not $wtSettings.profiles.defaults) {
                                    $wtSettings.profiles | Add-Member -NotePropertyName 'defaults' -NotePropertyValue @{} -Force
                                }
                                if (-not $wtSettings.profiles.defaults.font) {
                                    $wtSettings.profiles.defaults | Add-Member -NotePropertyName 'font' -NotePropertyValue @{} -Force
                                }
                                $wtSettings.profiles.defaults.font | Add-Member -NotePropertyName 'face' -NotePropertyValue $terminalFontName -Force
                                $wtSettings | ConvertTo-Json -Depth 10 | Set-Content $wtSettingsPath -Encoding UTF8
                                Write-Host " ✓" -ForegroundColor Green
                            }
                        } else {
                            Write-Host " • Windows Terminal font already set to '$terminalFontName'" -ForegroundColor Gray
                        }
                    } catch {
                        Write-Host " • Could not configure Windows Terminal: $_" -ForegroundColor Yellow
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
                
                $anyNewlyInstalled = $false
                foreach ($ext in $Configuration.firefoxExtensions) {
                    $extFile = Join-Path $extensionsDir "$($ext.id).xpi"
                    
                    if (Test-Path $extFile) {
                        Write-Host " • $($ext.name) already installed" -ForegroundColor Gray
                    } else {
                        $anyNewlyInstalled = $true
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
                
                if ($anyNewlyInstalled) {
                    Write-Host " ! Restart Firefox to activate extensions" -ForegroundColor Yellow
                }
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

    # --- Dotnet Tools ---
    if ($Configuration.dotnetTools -and $Configuration.dotnetTools.Count -gt 0) {
        Write-Host "`n=== Dotnet Tools ===" -ForegroundColor Cyan
        
        $dotnetAvailable = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($dotnetAvailable) {
            foreach ($tool in $Configuration.dotnetTools) {
                $toolStatus = $PreFlightStatus.DotnetTools | Where-Object { $_.Id -eq $tool.id }
                
                if ($toolStatus -and $toolStatus.Installed) {
                    Write-Host " • $($tool.name) already installed" -ForegroundColor Gray
                } else {
                    if ($IsDryRun) {
                        Write-Host " • [DRY RUN] Would install $($tool.id)" -ForegroundColor Cyan
                    } else {
                        Write-Host " • Installing $($tool.name)..." -ForegroundColor Green -NoNewline
                        $installResult = dotnet tool install --global $tool.id 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host " ✓" -ForegroundColor Green
                        } else {
                            Write-Host " ✗" -ForegroundColor Red
                            Write-Host "   Error: $installResult" -ForegroundColor Red
                        }
                    }
                }
            }
        } else {
            Write-Host " ! .NET SDK is not available. Install .NET SDK first." -ForegroundColor Yellow
        }
    }

    # --- Backup Configuration ---
    if ($Configuration.backups -and $Configuration.backups.Count -gt 0) {
        Write-Host "`n=== Backup Configuration ===" -ForegroundColor Cyan
        
        foreach ($backup in $Configuration.backups) {
            if (-not $backup.enabled) {
                Write-Host " • Backup → $($backup.destinationPath) [DISABLED]" -ForegroundColor Gray
                continue
            }

            $backupType = if ($backup.type) { $backup.type } else { "FileHistory" }
            
            # Check pre-flight status to skip already configured backups
            $backupStatus = $PreFlightStatus.Backups | Where-Object { $_.Type -eq $backupType -and $_.Destination -eq $backup.destinationPath }
            if ($backupStatus -and $backupStatus.Configured) {
                Write-Host " • $backupType → $($backup.destinationPath) [Already configured]" -ForegroundColor Gray
                continue
            }
            
            Write-Host " • Configuring $backupType → $($backup.destinationPath)" -ForegroundColor Green
            
            if ($backupType -eq "FileHistory") {
                # Check destination drive exists and has adequate space
                $destDrive = Split-Path -Qualifier $backup.destinationPath
                if (-not (Test-Path $destDrive)) {
                    Write-Host "   ✗ Destination drive $destDrive not found - skipping" -ForegroundColor Red
                    continue
                }
                
                $minSpaceGB = if ($backup.minFreeSpaceGB) { $backup.minFreeSpaceGB } else { 50 }
                $driveInfo = Get-PSDrive -Name ($destDrive -replace ':', '') -ErrorAction SilentlyContinue
                if ($driveInfo) {
                    $freeSpaceGB = [math]::Round($driveInfo.Free / 1GB, 1)
                    if ($freeSpaceGB -lt $minSpaceGB) {
                        Write-Host "   ⚠ Warning: Only ${freeSpaceGB}GB free on $destDrive (minimum: ${minSpaceGB}GB)" -ForegroundColor Yellow
                    } else {
                        Write-Host "   ✓ ${freeSpaceGB}GB free on $destDrive" -ForegroundColor Gray
                    }
                }
                
                # Ensure destination directory exists
                if (-not (Test-Path $backup.destinationPath)) {
                    if ($IsDryRun) {
                        Write-Host "   [DRY RUN] Would create directory: $($backup.destinationPath)" -ForegroundColor Cyan
                    } else {
                        Write-Host "   Creating backup directory..." -ForegroundColor Yellow
                        New-Item -ItemType Directory -Path $backup.destinationPath -Force | Out-Null
                    }
                }

                # Check if File History has data in the destination (Configuration folder exists)
                $fhConfigPath = Join-Path $backup.destinationPath "Configuration"
                if (Test-Path $fhConfigPath) {
                    Write-Host "   ✓ File History already configured to $($backup.destinationPath)" -ForegroundColor Gray
                } else {
                    if ($IsDryRun) {
                        Write-Host "   [DRY RUN] Would open File History settings" -ForegroundColor Cyan
                    } else {
                        Write-Host "   ⚠ File History needs manual configuration" -ForegroundColor Yellow
                        Write-Host "   → Opening Backup Settings... (select '$($backup.destinationPath)' as backup drive)" -ForegroundColor Cyan
                        Start-Process "ms-settings:backup"
                    }
                }
            } elseif ($backupType -eq "BitLockerKeys") {
                # Backup BitLocker recovery keys
                if (-not (Test-Path $backup.destinationPath)) {
                    if ($IsDryRun) {
                        Write-Host "   [DRY RUN] Would create directory: $($backup.destinationPath)" -ForegroundColor Cyan
                    } else {
                        Write-Host "   Creating backup directory..." -ForegroundColor Yellow
                        New-Item -ItemType Directory -Path $backup.destinationPath -Force | Out-Null
                    }
                }
                
                try {
                    # Check for encrypted volumes (FullyEncrypted or EncryptionInProgress), not just protection status
                    $bitlockerVolumes = Get-BitLockerVolume -ErrorAction Stop | Where-Object { 
                        $_.VolumeStatus -eq 'FullyEncrypted' -or $_.VolumeStatus -eq 'EncryptionInProgress' 
                    }
                    
                    if (-not $bitlockerVolumes) {
                        Write-Host "   ✓ No BitLocker-encrypted volumes found" -ForegroundColor Gray
                    } else {
                        foreach ($vol in $bitlockerVolumes) {
                            # Skip volumes without a proper drive letter (e.g., \\?\Volume{GUID})
                            if ($vol.MountPoint -notmatch '^[A-Z]:') {
                                continue
                            }
                            
                            $driveLetter = $vol.MountPoint -replace ':', ''
                            $keyFile = Join-Path $backup.destinationPath "BitLocker-$env:COMPUTERNAME-${driveLetter}-$(Get-Date -Format 'yyyy-MM-dd').txt"
                            
                            # Check if we already have a backup from today
                            if (Test-Path $keyFile) {
                                Write-Host "   ✓ $($vol.MountPoint) key already backed up today" -ForegroundColor Gray
                                continue
                            }
                            
                            if ($IsDryRun) {
                                Write-Host "   [DRY RUN] Would backup $($vol.MountPoint) recovery key to $keyFile" -ForegroundColor Cyan
                            } else {
                                # Get recovery password protectors
                                $recoveryProtectors = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }
                                
                                if ($recoveryProtectors) {
                                    $content = @()
                                    $content += "BitLocker Recovery Key Backup"
                                    $content += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                                    $content += "Computer: $env:COMPUTERNAME"
                                    $content += "Volume: $($vol.MountPoint) ($($vol.VolumeType))"
                                    $content += "-" * 50
                                    
                                    foreach ($protector in $recoveryProtectors) {
                                        $content += ""
                                        $content += "Key ID: $($protector.KeyProtectorId)"
                                        $content += "Recovery Password: $($protector.RecoveryPassword)"
                                    }
                                    
                                    $content | Out-File -FilePath $keyFile -Encoding UTF8
                                    Write-Host "   ✓ $($vol.MountPoint) recovery key saved to $keyFile" -ForegroundColor Green
                                } else {
                                    Write-Host "   ⚠ $($vol.MountPoint) has no recovery password protector" -ForegroundColor Yellow
                                }
                            }
                        }
                    }
                } catch {
                    Write-Host "   ✗ Failed to backup BitLocker keys: $_" -ForegroundColor Red
                    Write-Host "   → Run as Administrator to access BitLocker info" -ForegroundColor Yellow
                }
            } elseif ($backupType -eq "WindowsBackup") {
                # Check Windows Backup status
                try {
                    $wbReg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppListBackup" -ErrorAction Stop
                    if ($wbReg.IsBackupEnabledAndMSAAttached -eq 1) {
                        Write-Host "   ✓ Windows Backup is enabled and syncing to Microsoft account" -ForegroundColor Gray
                    } else {
                        if ($IsDryRun) {
                            Write-Host "   [DRY RUN] Would open Windows Backup settings" -ForegroundColor Cyan
                        } else {
                            Write-Host "   ⚠ Windows Backup needs to be enabled" -ForegroundColor Yellow
                            Write-Host "   → Opening Windows Backup settings..." -ForegroundColor Cyan
                            Start-Process "ms-settings:backup"
                        }
                    }
                } catch {
                    if ($IsDryRun) {
                        Write-Host "   [DRY RUN] Would open Windows Backup settings" -ForegroundColor Cyan
                    } else {
                        Write-Host "   ⚠ Windows Backup not configured" -ForegroundColor Yellow
                        Write-Host "   → Opening Windows Backup settings..." -ForegroundColor Cyan
                        Start-Process "ms-settings:backup"
                    }
                }
            } else {
                Write-Host "   ! Unsupported backup type: $backupType" -ForegroundColor Yellow
                Write-Host "   Currently supported: WindowsBackup, BitLockerKeys, FileHistory" -ForegroundColor Yellow
            }
        }
    }

    # --- Windows Settings Configuration ---
    if ($Configuration.windowsSettings) {
        $needsConfig = $false
        if ($PreFlightStatus.WindowsSettings) {
            if ($PreFlightStatus.WindowsSettings.ShowFileExtensions -and -not $PreFlightStatus.WindowsSettings.ShowFileExtensions.Configured) {
                $needsConfig = $true
            }
            if ($PreFlightStatus.WindowsSettings.ShowHiddenFiles -and -not $PreFlightStatus.WindowsSettings.ShowHiddenFiles.Configured) {
                $needsConfig = $true
            }
            if ($PreFlightStatus.WindowsSettings.DarkMode -and -not $PreFlightStatus.WindowsSettings.DarkMode.Configured) {
                $needsConfig = $true
            }
            if ($PreFlightStatus.WindowsSettings.DesktopWallpaper -and -not $PreFlightStatus.WindowsSettings.DesktopWallpaper.Configured) {
                $needsConfig = $true
            }
            if ($PreFlightStatus.WindowsSettings.Taskbar) {
                if ($PreFlightStatus.WindowsSettings.Taskbar.Alignment -and -not $PreFlightStatus.WindowsSettings.Taskbar.Alignment.Configured) {
                    $needsConfig = $true
                }
                if ($PreFlightStatus.WindowsSettings.Taskbar.ShowWidgets -and -not $PreFlightStatus.WindowsSettings.Taskbar.ShowWidgets.Configured) {
                    $needsConfig = $true
                }
                if ($PreFlightStatus.WindowsSettings.Taskbar.ShowSearch -and -not $PreFlightStatus.WindowsSettings.Taskbar.ShowSearch.Configured) {
                    $needsConfig = $true
                }
            }
        }
        
        if ($needsConfig) {
            Write-Host "`n=== Windows Settings ===" -ForegroundColor Cyan
            
            # File Extensions
            if ($PreFlightStatus.WindowsSettings.ShowFileExtensions -and -not $PreFlightStatus.WindowsSettings.ShowFileExtensions.Configured) {
                $desired = $Configuration.windowsSettings.showFileExtensions
                $hideValue = if ($desired) { 0 } else { 1 }
                if ($IsDryRun) {
                    Write-Host " • [DRY RUN] Would set file extensions to $(if ($desired) { 'visible' } else { 'hidden' })" -ForegroundColor Cyan
                } else {
                    Write-Host " • Setting file extensions to $(if ($desired) { 'visible' } else { 'hidden' })..." -ForegroundColor Green -NoNewline
                    Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value $hideValue
                    Write-Host " ✓" -ForegroundColor Green
                }
            }
            
            # Hidden Files
            if ($PreFlightStatus.WindowsSettings.ShowHiddenFiles -and -not $PreFlightStatus.WindowsSettings.ShowHiddenFiles.Configured) {
                $desired = $Configuration.windowsSettings.showHiddenFiles
                $hiddenValue = if ($desired) { 1 } else { 2 }
                if ($IsDryRun) {
                    Write-Host " • [DRY RUN] Would set hidden files to $(if ($desired) { 'visible' } else { 'hidden' })" -ForegroundColor Cyan
                } else {
                    Write-Host " • Setting hidden files to $(if ($desired) { 'visible' } else { 'hidden' })..." -ForegroundColor Green -NoNewline
                    Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -Value $hiddenValue
                    Write-Host " ✓" -ForegroundColor Green
                }
            }
            
            # Dark Mode
            if ($PreFlightStatus.WindowsSettings.DarkMode -and -not $PreFlightStatus.WindowsSettings.DarkMode.Configured) {
                $desired = $Configuration.windowsSettings.darkMode
                $lightValue = if ($desired) { 0 } else { 1 }
                if ($IsDryRun) {
                    Write-Host " • [DRY RUN] Would set theme to $(if ($desired) { 'dark' } else { 'light' }) mode" -ForegroundColor Cyan
                } else {
                    Write-Host " • Setting theme to $(if ($desired) { 'dark' } else { 'light' }) mode..." -ForegroundColor Green -NoNewline
                    Set-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -Value $lightValue
                    Set-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "SystemUsesLightTheme" -Value $lightValue
                    Write-Host " ✓" -ForegroundColor Green
                }
            }
            
            # Desktop Wallpaper
            if ($PreFlightStatus.WindowsSettings.DesktopWallpaper -and -not $PreFlightStatus.WindowsSettings.DesktopWallpaper.Configured) {
                $desiredWallpaper = $Configuration.windowsSettings.desktopWallpaper
                if ($IsDryRun) {
                    Write-Host " • [DRY RUN] Would set desktop wallpaper to $desiredWallpaper" -ForegroundColor Cyan
                } else {
                    Write-Host " • Setting desktop wallpaper..." -ForegroundColor Green -NoNewline
                    # Use SystemParametersInfo to set wallpaper properly
                    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Wallpaper {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
                    [Wallpaper]::SystemParametersInfo(0x0014, 0, $desiredWallpaper, 0x01 -bor 0x02) | Out-Null
                    Write-Host " ✓" -ForegroundColor Green
                }
            }
            
            # Taskbar Settings
            if ($PreFlightStatus.WindowsSettings.Taskbar) {
                $taskbarChanged = $false
                
                # Taskbar Alignment
                if ($PreFlightStatus.WindowsSettings.Taskbar.Alignment -and -not $PreFlightStatus.WindowsSettings.Taskbar.Alignment.Configured) {
                    $desired = $Configuration.windowsSettings.taskbar.alignment
                    $alignValue = if ($desired -eq "left") { 0 } else { 1 }
                    if ($IsDryRun) {
                        Write-Host " • [DRY RUN] Would set taskbar alignment to $desired" -ForegroundColor Cyan
                    } else {
                        Write-Host " • Setting taskbar alignment to $desired..." -ForegroundColor Green -NoNewline
                        Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarAl" -Value $alignValue
                        Write-Host " ✓" -ForegroundColor Green
                        $taskbarChanged = $true
                    }
                }
                
                # Widgets
                if ($PreFlightStatus.WindowsSettings.Taskbar.ShowWidgets -and -not $PreFlightStatus.WindowsSettings.Taskbar.ShowWidgets.Configured) {
                    $desired = $Configuration.windowsSettings.taskbar.showWidgets
                    $widgetValue = if ($desired) { 1 } else { 0 }
                    if ($IsDryRun) {
                        Write-Host " • [DRY RUN] Would $(if ($desired) { 'show' } else { 'hide' }) widgets" -ForegroundColor Cyan
                    } else {
                        Write-Host " • $(if ($desired) { 'Showing' } else { 'Hiding' }) widgets..." -ForegroundColor Green -NoNewline
                        Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Value $widgetValue
                        Write-Host " ✓" -ForegroundColor Green
                        $taskbarChanged = $true
                    }
                }
                
                # Search
                if ($PreFlightStatus.WindowsSettings.Taskbar.ShowSearch -and -not $PreFlightStatus.WindowsSettings.Taskbar.ShowSearch.Configured) {
                    $desired = $Configuration.windowsSettings.taskbar.showSearch
                    $searchValue = if ($desired) { 1 } else { 0 }
                    if ($IsDryRun) {
                        Write-Host " • [DRY RUN] Would $(if ($desired) { 'show' } else { 'hide' }) search" -ForegroundColor Cyan
                    } else {
                        Write-Host " • $(if ($desired) { 'Showing' } else { 'Hiding' }) search..." -ForegroundColor Green -NoNewline
                        Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode" -Value $searchValue
                        Write-Host " ✓" -ForegroundColor Green
                        $taskbarChanged = $true
                    }
                }
                
                # Restart Explorer if taskbar settings changed
                if ($taskbarChanged -and -not $IsDryRun) {
                    Write-Host " • Restarting Explorer for taskbar changes..." -ForegroundColor Green -NoNewline
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                    Start-Process explorer
                    Write-Host " ✓" -ForegroundColor Green
                }
            }
            
            # Refresh Explorer to apply changes (only for file/folder settings, if not already restarted)
            if (-not $IsDryRun -and -not $taskbarChanged) {
                $needsExplorerRefresh = ($PreFlightStatus.WindowsSettings.ShowFileExtensions -and -not $PreFlightStatus.WindowsSettings.ShowFileExtensions.Configured) -or
                                        ($PreFlightStatus.WindowsSettings.ShowHiddenFiles -and -not $PreFlightStatus.WindowsSettings.ShowHiddenFiles.Configured)
                if ($needsExplorerRefresh) {
                    Write-Host " • Refreshing Explorer..." -ForegroundColor Green -NoNewline
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                    Start-Process explorer
                    Write-Host " ✓" -ForegroundColor Green
                }
            }
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
        # Update Backups that were configured
        if ($PreFlightStatus.Backups) {
            foreach ($backup in $PreFlightStatus.Backups) {
                if ($backup.Action -eq "Configure") {
                    $backup.Configured = $true
                    $backup.Action = "Skip"
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
        
        # Check for new backup configs
        $newBackups = @()
        if (-not $preFlightStatus.Backups) {
            $preFlightStatus.Backups = @()
        }
        if ($config.backups) {
            foreach ($backup in $config.backups) {
                $backupType = if ($backup.type) { $backup.type } else { "FileHistory" }
                $destForMatch = if ($backup.destinationPath) { $backup.destinationPath } else { "" }
                $cached = $preFlightStatus.Backups | Where-Object { $_.Type -eq $backupType -and $_.Destination -eq $destForMatch }
                if (-not $cached) {
                    $displayDest = if ($backup.destinationPath) { " → $($backup.destinationPath)" } else { "" }
                    Write-Host "🔍 Checking new backup config: $backupType$displayDest..." -ForegroundColor Cyan -NoNewline
                    $isConfigured = $false
                    if ($backupType -eq "FileHistory") {
                        try {
                            $fhConfig = Get-CimInstance -Namespace root/Microsoft/Windows/FileHistory -ClassName MSFT_FhConfigInfo -ErrorAction Stop
                            $isConfigured = ($fhConfig.BackupLocation -eq $backup.destinationPath -and $fhConfig.Enabled)
                        } catch {
                            # Fallback: check if FileHistory config folder exists in the destination
                            $fhConfigPath = Join-Path $backup.destinationPath "Configuration"
                            $isConfigured = (Test-Path $fhConfigPath)
                        }
                    } elseif ($backupType -eq "BitLockerKeys") {
                        if (Test-Path $backup.destinationPath) {
                            $todayFiles = Get-ChildItem -Path $backup.destinationPath -Filter "BitLocker-$env:COMPUTERNAME-*-$(Get-Date -Format 'yyyy-MM-dd').txt" -ErrorAction SilentlyContinue
                            $isConfigured = ($todayFiles.Count -gt 0)
                        }
                    } elseif ($backupType -eq "WindowsBackup") {
                        try {
                            $wbReg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppListBackup" -ErrorAction Stop
                            $isConfigured = ($wbReg.IsBackupEnabledAndMSAAttached -eq 1)
                        } catch {
                            $isConfigured = $false
                        }
                    }
                    $preFlightStatus.Backups += [PSCustomObject]@{
                        Type = $backupType
                        Destination = $backup.destinationPath
                        Configured = $isConfigured
                        Action = if (-not $backup.enabled) { "Disabled" } elseif ($isConfigured) { "Skip" } else { "Configure" }
                    }
                    Write-Host $(if ($isConfigured) { " ✓ configured" } elseif (-not $backup.enabled) { " disabled" } else { " needs config" }) -ForegroundColor $(if ($isConfigured) { 'Green' } elseif (-not $backup.enabled) { 'Gray' } else { 'Yellow' })
                    $newBackups += $backupType
                }
            }
        }
        
        if ($newTools.Count -gt 0 -or $newBackups.Count -gt 0) {
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