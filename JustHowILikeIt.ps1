# Automatically set execution policy for this session to allow the script to run
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force

<#
.SYNOPSIS
    Automates the installation of common developer tools using WinGet.
    
.DESCRIPTION
    This script installs a curated list of developer applications including:
    Visual Studio 2026, VS Code, Node.js, WSL, and Oh My Posh.
    It now ensures the Oh My Posh profile configuration is in a 'Desired State'.
#>

# Define the list of tools to install (App ID from winget)
$tools = @(
    # --- CORE TERMINAL & SHELL ---
    "Microsoft.PowerShell",             # The latest version of PowerShell core
    "JanDeDobbeleer.OhMyPosh",          # Custom prompt engine
    
    # --- IDEs & EDITORS ---
    "Microsoft.VisualStudio.2026.Professional", # Visual Studio 2026 Pro (Requires your license)
    "Microsoft.VisualStudioCode",       # Lightweight code editor
    "Notepad++.Notepad++",              # Fast source code editor
    
    # --- SOURCE CONTROL & CLI ---
    "Git.Git",                          # Distributed version control system
    "GitHub.cli",                       # GitHub's official command line interface
    
    # --- LANGUAGES & RUNTIMES ---
    "OpenJS.NodeJS",                    # JavaScript runtime
    "Microsoft.WSL",                    # Windows Subsystem for Linux
    
    # --- BROWSERS ---
    "Mozilla.Firefox",                  # Privacy-focused web browser
    "Google.Chrome",                    # Popular web browser for testing
    
    # --- UTILITIES ---
    "KeePassXCTeam.KeePassXC",          # Cross-platform password manager
    "Docker.DockerDesktop",             # Container management
    "Postman.Postman",                  # API platform for designing and testing APIs
    "Microsoft.PowerToys",              # Productivity utilities
    "7zip.7zip",                        # File archiver
    "Microsoft.CascadiaCode"            # Font with programming ligatures
)

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
    # Output a starting message to the console in cyan
    Write-Host "--- Starting Developer Environment Setup (Desired State) ---" -ForegroundColor Cyan
    
    # Check if WinGet is present before proceeding
    if (-not (Test-WinGet)) {
        # Output error message if winget is missing
        Write-Host "Error: WinGet is not installed. Please install it from the Microsoft Store." -ForegroundColor Red
        # Exit the function
        return
    }

    # Iterate through each tool defined in the tools array
    foreach ($toolId in $tools) {
        # Display the current tool being checked in yellow
        Write-Host "`n[Checking] $toolId..." -ForegroundColor Yellow
        
        # Search for the exact ID and check if the result is not null/empty
        $checkInstalled = winget list --id $toolId --exact --source winget 2>$null | Out-String
        
        # If the output doesn't contain the tool ID, it's likely not installed
        if ($checkInstalled -match [regex]::Escape($toolId)) {
            # Notify the user that the tool is already present
            Write-Host " - $toolId is already installed. Skipping..." -ForegroundColor Gray
        }
        else {
            # Notify the user that the installation is starting
            Write-Host " - Installing $toolId..." -ForegroundColor Green
            # Execute winget install with silent flags and agreement acceptance
            winget install --id $toolId --silent --accept-package-agreements --accept-source-agreements
            
            # Check the exit code of the last command
            if ($LASTEXITCODE -eq 0) {
                # Success message
                Write-Host " - Successfully installed $toolId" -ForegroundColor Green
            } else {
                # Error message with the specific exit code returned by winget
                Write-Host " - Failed to install $toolId (Exit Code: $LASTEXITCODE)" -ForegroundColor Red
            }
        }
    }

    # --- GitHub Copilot CLI Extension Setup ---
    Write-Host "`n[Checking] GitHub Copilot CLI Extension..." -ForegroundColor Yellow
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        Write-Host " - Ensuring GitHub Copilot extension is installed..." -ForegroundColor Green
        gh extension install github/gh-copilot --force
        
        $authStatus = gh auth status 2>&1
        if ($authStatus -match "Logged in to github.com") {
            Write-Host " - GitHub CLI is already authenticated." -ForegroundColor Gray
        } else {
            Write-Host " ! REMINDER: Run 'gh auth login' to enable Copilot CLI features." -ForegroundColor Magenta
        }
    }

    # --- Oh My Posh Desired State Configuration ---
    Write-Host "`n[Desired State] Oh My Posh Configuration..." -ForegroundColor Yellow
    if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
        # Define the desired init line for the marcduiker theme
        $poshInitLine = 'oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\marcduiker.omp.json" | Invoke-Expression'
        
        # Check if the profile file exists, if not create it
        if (-not (Test-Path $PROFILE)) {
            New-Item -Path $PROFILE -Type File -Force | Out-Null
            Write-Host " - Created new PowerShell profile." -ForegroundColor Gray
        }

        # Read the current profile content
        $profileContent = Get-Content $PROFILE -Raw
        
        # Check if the init line already exists in the profile
        if ($profileContent -match [regex]::Escape($poshInitLine)) {
            Write-Host " - Oh My Posh (marcduiker theme) is already configured in profile." -ForegroundColor Gray
        } else {
            Write-Host " - Adding marcduiker theme configuration to `$PROFILE..." -ForegroundColor Green
            Add-Content -Path $PROFILE -Value "`n# Oh My Posh Configuration`n$poshInitLine"
            Write-Host " - Profile updated successfully." -ForegroundColor Green
        }
    }

    # Final summary and cleanup messages
    Write-Host "`n--- Setup Complete! ---" -ForegroundColor Cyan
    Write-Host "Note: REBOOT REQUIRED for WSL, Docker, and Visual Studio to finalize installation." -ForegroundColor White -BackgroundColor Red
    Write-Host "Restart your terminal to see the new Oh My Posh theme." -ForegroundColor Yellow
}

# Execute the main function to begin the process
Install-Tools
