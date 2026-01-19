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
    
.EXAMPLE
    .\JustHowILikeIt.ps1
    (Uses default config file in script directory)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

# Automatically set execution policy for this session to allow the script to run
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force

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

# Function to check if a tool is already installed
function Test-ToolInstalled {
    param(
        [string]$ToolId
    )
    
    try {
        $checkInstalled = winget list --id $ToolId --exact --source winget 2>$null | Out-String
        return ($checkInstalled -match [regex]::Escape($ToolId))
    }
    catch {
        return $false
    }
}

# Function to perform pre-flight checks
function Get-PreFlightStatus {
    param($Configuration)
    
    $status = @{
        Tools = @()
        GitHubCLI = $null
        OhMyPosh = $null
        Repository = $null
    }
    
    # Check each tool
    foreach ($tool in $Configuration.tools) {
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
    if ($Configuration.repository.owner -and $Configuration.repository.name) {
        $repoPath = [Environment]::ExpandEnvironmentVariables($Configuration.repository.clonePath)
        $repoExists = Test-Path $repoPath
        
        $status.Repository = [PSCustomObject]@{
            Path = $repoPath
            Exists = $repoExists
            Action = if ($repoExists) { "Pull updates" } else { "Clone" }
        }
    }
    
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
        [bool]$IsDryRun = $false
    )
    
    # Output a starting message to the console in cyan
    if ($IsDryRun) {
        Write-Host "`n=== DRY RUN MODE - No changes will be made ===" -ForegroundColor Magenta
    } else {
        Write-Host "`n=== Starting Developer Environment Setup (Desired State) ===" -ForegroundColor Cyan
    }
    Write-Host "User: $($Configuration.user.name) (@$($Configuration.user.githubUsername))" -ForegroundColor Gray
    Write-Host "Tools to install: $($Configuration.tools.Count)" -ForegroundColor Gray
    Write-Host ""
    
    # Check if WinGet is present before proceeding
    if (-not (Test-WinGet)) {
        # Output error message if winget is missing
        Write-Host "Error: WinGet is not installed. Please install it from the Microsoft Store." -ForegroundColor Red
        # Exit the function
        return
    }

    # Iterate through each tool defined in the configuration
    foreach ($tool in $Configuration.tools) {
        $toolId = $tool.id
        $toolName = $tool.name
        
        # Display the current tool being checked in yellow
        Write-Host "`n[Checking] $toolName ($toolId)..." -ForegroundColor Yellow
        
        # Search for the exact ID and check if the result is not null/empty
        $checkInstalled = winget list --id $toolId --exact --source winget 2>$null | Out-String
        
        # If the output doesn't contain the tool ID, it's likely not installed
        if ($checkInstalled -match [regex]::Escape($toolId)) {
            # Notify the user that the tool is already present
            Write-Host " - $toolName is already installed. Skipping..." -ForegroundColor Gray
        }
        else {
            if ($IsDryRun) {
                # In dry run mode, just show what would be installed
                Write-Host " - [DRY RUN] Would install $toolName" -ForegroundColor Cyan
            } else {
                # Notify the user that the installation is starting
                Write-Host " - Installing $toolName..." -ForegroundColor Green
                # Execute winget install with silent flags and agreement acceptance
                winget install --id $toolId --silent --accept-package-agreements --accept-source-agreements
                
                # Check the exit code of the last command
                if ($LASTEXITCODE -eq 0) {
                    # Success message
                    Write-Host " - Successfully installed $toolName" -ForegroundColor Green
                } else {
                    # Error message with the specific exit code returned by winget
                    Write-Host " - Failed to install $toolName (Exit Code: $LASTEXITCODE)" -ForegroundColor Red
                }
            }
        }
    }

    # --- GitHub CLI Setup & Authentication ---
    Write-Host "`n[Desired State] GitHub CLI Configuration..." -ForegroundColor Yellow
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        # Check authentication status
        $authStatus = gh auth status 2>&1
        if ($authStatus -match "Logged in to github.com") {
            Write-Host " - GitHub CLI is already authenticated." -ForegroundColor Gray
        } else {
            if ($IsDryRun) {
                Write-Host " - [DRY RUN] Would authenticate with GitHub" -ForegroundColor Cyan
            } else {
                Write-Host " - Authenticating with GitHub..." -ForegroundColor Green
                Write-Host " ! Please follow the prompts to authenticate..." -ForegroundColor Cyan
                gh auth login
            }
        }
        
        # Install GitHub Copilot CLI extension
        if ($IsDryRun) {
            Write-Host " - [DRY RUN] Would install GitHub Copilot extension" -ForegroundColor Cyan
        } else {
            Write-Host " - Ensuring GitHub Copilot extension is installed..." -ForegroundColor Green
            gh extension install github/gh-copilot --force 2>$null
        }
        
        # Clone/sync repository if configured
        if ($Configuration.repository.owner -and $Configuration.repository.name) {
            Write-Host " - Setting up $($Configuration.repository.name) repository..." -ForegroundColor Green
            $repoPath = [Environment]::ExpandEnvironmentVariables($Configuration.repository.clonePath)
            $repoFullName = "$($Configuration.repository.owner)/$($Configuration.repository.name)"
            
            if (Test-Path $repoPath) {
                Write-Host " - Repository already exists at $repoPath" -ForegroundColor Gray
                if ($IsDryRun) {
                    Write-Host " - [DRY RUN] Would pull latest changes" -ForegroundColor Cyan
                } else {
                    Write-Host " - Pulling latest changes..." -ForegroundColor Green
                    Push-Location $repoPath
                    git pull origin main 2>$null
                    Pop-Location
                }
            } else {
                if ($IsDryRun) {
                    Write-Host " - [DRY RUN] Would clone repository to $repoPath" -ForegroundColor Cyan
                } else {
                    Write-Host " - Cloning repository to $repoPath..." -ForegroundColor Green
                    gh repo clone $repoFullName $repoPath
                }
            }
            
            # Copy this script to the repository if authenticated
            if ($authStatus -match "Logged in to github.com" -or (gh auth status 2>&1) -match "Logged in to github.com") {
                $scriptSource = $PSCommandPath
                $scriptDest = Join-Path $repoPath "JustHowILikeIt.ps1"
                
                if (Test-Path $scriptSource) {
                    if ($IsDryRun) {
                        Write-Host " - [DRY RUN] Would sync script to: $scriptDest" -ForegroundColor Cyan
                    } else {
                        Write-Host " - Syncing current script to repository..." -ForegroundColor Green
                        Copy-Item -Path $scriptSource -Destination $scriptDest -Force
                        Write-Host " - Script synced to: $scriptDest" -ForegroundColor Gray
                        Write-Host " ! Run 'cd $repoPath; git add .; git commit -m ""Update script""; git push' to push changes" -ForegroundColor Magenta
                    }
                }
            }
        }
    } else {
        Write-Host " ! GitHub CLI not found. It will be installed by this script." -ForegroundColor Yellow
    }

    # --- Oh My Posh Desired State Configuration ---
    if ($Configuration.ohMyPosh.enabled) {
        Write-Host "`n[Desired State] Oh My Posh Configuration..." -ForegroundColor Yellow
        if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
            # Define the desired init line for the configured theme
            $themeName = $Configuration.ohMyPosh.theme
            $poshInitLine = "oh-my-posh init pwsh --config `"`$env:POSH_THEMES_PATH\$themeName.omp.json`" | Invoke-Expression"
            
            # Check if the profile file exists, if not create it
            if (-not (Test-Path $PROFILE)) {
                if ($IsDryRun) {
                    Write-Host " - [DRY RUN] Would create new PowerShell profile" -ForegroundColor Cyan
                } else {
                    New-Item -Path $PROFILE -Type File -Force | Out-Null
                    Write-Host " - Created new PowerShell profile." -ForegroundColor Gray
                }
            }

            # Read the current profile content
            $profileContent = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { "" }
            
            # Check if the init line already exists in the profile
            if ($profileContent -match [regex]::Escape($poshInitLine)) {
                Write-Host " - Oh My Posh ($themeName theme) is already configured in profile." -ForegroundColor Gray
            } else {
                if ($IsDryRun) {
                    Write-Host " - [DRY RUN] Would add $themeName theme configuration to `$PROFILE" -ForegroundColor Cyan
                } else {
                    Write-Host " - Adding $themeName theme configuration to `$PROFILE..." -ForegroundColor Green
                    Add-Content -Path $PROFILE -Value "`n# Oh My Posh Configuration`n$poshInitLine"
                    Write-Host " - Profile updated successfully." -ForegroundColor Green
                }
            }
        }
    }

    # Final summary and cleanup messages
    if ($IsDryRun) {
        Write-Host "`n=== DRY RUN Complete! ===" -ForegroundColor Magenta
        Write-Host "No changes were made. Run without -DryRun to apply changes." -ForegroundColor Yellow
    } else {
        Write-Host "`n=== Setup Complete! ===" -ForegroundColor Cyan
        Write-Host "Note: REBOOT REQUIRED for WSL, Docker, and Visual Studio to finalize installation." -ForegroundColor White -BackgroundColor Red
        if ($Configuration.ohMyPosh.enabled) {
            Write-Host "Restart your terminal to see the new Oh My Posh theme." -ForegroundColor Yellow
        }
    }
}

# Run pre-flight checks first
$preFlightStatus = Get-PreFlightStatus -Configuration $config
Show-PreFlightStatus -Status $preFlightStatus

if ($DryRun) {
    Write-Host "Running in DRY RUN mode..." -ForegroundColor Magenta
    Install-Tools -Configuration $config -IsDryRun $true
} else {
    # Ask for confirmation before proceeding
    $proceed = Read-Host "`nProceed with installation? (Y/n)"
    if ($proceed -eq "" -or $proceed -eq "Y" -or $proceed -eq "y") {
        Install-Tools -Configuration $config -IsDryRun $false
    } else {
        Write-Host "Installation cancelled." -ForegroundColor Yellow
    }
}