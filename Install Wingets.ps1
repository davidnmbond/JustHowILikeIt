<#
.SYNOPSIS
    Automates the installation of developer tools using WinGet based on a configuration file.
    
.DESCRIPTION
    This script installs applications from a customizable configuration file.
    It supports WinGet package installation, Oh My Posh theming, and GitHub repository setup.
    Users can create their own config files to define their preferred tools and settings.
    
.PARAMETER ConfigFile
    Path to the JSON configuration file. If not specified, looks for a config file in the script directory.
    
.EXAMPLE
    .\JustHowILikeIt.ps1 -ConfigFile ".\myconfig.json"
    
.EXAMPLE
    .\JustHowILikeIt.ps1
    (Uses default config file in script directory)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile
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
    param($Configuration)
    
    # Output a starting message to the console in cyan
    Write-Host "`n=== Starting Developer Environment Setup (Desired State) ===" -ForegroundColor Cyan
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

    # --- GitHub CLI Setup & Authentication ---
    Write-Host "`n[Desired State] GitHub CLI Configuration..." -ForegroundColor Yellow
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        # Check authentication status
        $authStatus = gh auth status 2>&1
        if ($authStatus -match "Logged in to github.com") {
            Write-Host " - GitHub CLI is already authenticated." -ForegroundColor Gray
        } else {
            Write-Host " - Authenticating with GitHub..." -ForegroundColor Green
            Write-Host " ! Please follow the prompts to authenticate..." -ForegroundColor Cyan
            gh auth login
        }
        
        # Install GitHub Copilot CLI extension
        Write-Host " - Ensuring GitHub Copilot extension is installed..." -ForegroundColor Green
        gh extension install github/gh-copilot --force 2>$null
        
        # Clone/sync repository if configured
        if ($Configuration.repository.owner -and $Configuration.repository.name) {
            Write-Host " - Setting up $($Configuration.repository.name) repository..." -ForegroundColor Green
            $repoPath = [Environment]::ExpandEnvironmentVariables($Configuration.repository.clonePath)
            $repoFullName = "$($Configuration.repository.owner)/$($Configuration.repository.name)"
            
            if (Test-Path $repoPath) {
                Write-Host " - Repository already exists at $repoPath" -ForegroundColor Gray
                Write-Host " - Pulling latest changes..." -ForegroundColor Green
                Push-Location $repoPath
                git pull origin main 2>$null
                Pop-Location
            } else {
                Write-Host " - Cloning repository to $repoPath..." -ForegroundColor Green
                gh repo clone $repoFullName $repoPath
            }
            
            # Copy this script to the repository if authenticated
            if ($authStatus -match "Logged in to github.com" -or (gh auth status 2>&1) -match "Logged in to github.com") {
                $scriptSource = $PSCommandPath
                $scriptDest = Join-Path $repoPath "JustHowILikeIt.ps1"
                
                if (Test-Path $scriptSource) {
                    Write-Host " - Syncing current script to repository..." -ForegroundColor Green
                    Copy-Item -Path $scriptSource -Destination $scriptDest -Force
                    Write-Host " - Script synced to: $scriptDest" -ForegroundColor Gray
                    Write-Host " ! Run 'cd $repoPath; git add .; git commit -m ""Update script""; git push' to push changes" -ForegroundColor Magenta
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
                New-Item -Path $PROFILE -Type File -Force | Out-Null
                Write-Host " - Created new PowerShell profile." -ForegroundColor Gray
            }

            # Read the current profile content
            $profileContent = Get-Content $PROFILE -Raw
            
            # Check if the init line already exists in the profile
            if ($profileContent -match [regex]::Escape($poshInitLine)) {
                Write-Host " - Oh My Posh ($themeName theme) is already configured in profile." -ForegroundColor Gray
            } else {
                Write-Host " - Adding $themeName theme configuration to `$PROFILE..." -ForegroundColor Green
                Add-Content -Path $PROFILE -Value "`n# Oh My Posh Configuration`n$poshInitLine"
                Write-Host " - Profile updated successfully." -ForegroundColor Green
            }
        }
    }

    # Final summary and cleanup messages
    Write-Host "`n=== Setup Complete! ===" -ForegroundColor Cyan
    Write-Host "Note: REBOOT REQUIRED for WSL, Docker, and Visual Studio to finalize installation." -ForegroundColor White -BackgroundColor Red
    if ($Configuration.ohMyPosh.enabled) {
        Write-Host "Restart your terminal to see the new Oh My Posh theme." -ForegroundColor Yellow
    }
}

# Execute the main function to begin the process
Install-Tools -Configuration $config