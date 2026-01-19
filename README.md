# JustHowILikeIt - Personal Machine Setup Script

A PowerShell script to automate the installation and configuration of your developer environment using WinGet and custom configuration files.

## Features

- ✅ Install any WinGet packages from a customizable list
- ✅ Configure Oh My Posh with your preferred theme
- ✅ Authenticate with GitHub CLI
- ✅ Clone and sync your personal repository
- ✅ Idempotent "Desired State" approach - safe to run multiple times
- ✅ User-specific configuration files

## Quick Start

1. **Create your configuration file**:
   - Copy `config.example.json` to `config.json` or `yourusername.config.json`
   - Edit the JSON file to include your preferences

2. **Run the script**:
   ```powershell
   .\JustHowILikeIt.ps1
   ```
   
   Or specify a custom config file:
   ```powershell
   .\JustHowILikeIt.ps1 -ConfigFile ".\myconfig.json"
   ```

## Configuration File Structure

```json
{
  "user": {
    "name": "Your Name",
    "githubUsername": "your-github-username",
    "email": "your.email@example.com"
  },
  "repository": {
    "owner": "your-github-username",
    "name": "JustHowILikeIt",
    "clonePath": "%USERPROFILE%\\JustHowILikeIt"
  },
  "ohMyPosh": {
    "theme": "marcduiker",
    "enabled": true
  },
  "tools": [
    {
      "id": "Microsoft.VisualStudioCode",
      "name": "VS Code",
      "category": "IDEs & EDITORS"
    }
  ]
}
```

### Configuration Sections

#### `user`
Your personal information used for git configuration and display purposes.

#### `repository`
Your GitHub repository settings where this script will be stored and synced.
- `owner`: Your GitHub username or organization
- `name`: Repository name
- `clonePath`: Local path where the repo will be cloned (supports environment variables)

#### `ohMyPosh`
Oh My Posh prompt theme configuration.
- `theme`: Name of the theme (without .omp.json extension)
- `enabled`: Set to `true` to configure Oh My Posh, `false` to skip

#### `tools`
Array of WinGet packages to install.
- `id`: WinGet package ID (required)
- `name`: Display name for the tool
- `category`: Category for organization (optional)

## Finding WinGet Package IDs

To find package IDs for tools you want to install:

```powershell
winget search "package name"
```

Use the exact ID from the search results in your config file.

## File Priority

The script looks for configuration files in this order:
1. File specified with `-ConfigFile` parameter
2. `config.json` in the script directory
3. `<username>.config.json` in the script directory
4. Other .config.json files in the script directory

## Examples

### Minimal Configuration
```json
{
  "user": {
    "name": "John Doe",
    "githubUsername": "johndoe",
    "email": "john@example.com"
  },
  "ohMyPosh": {
    "theme": "robbyrussell",
    "enabled": true
  },
  "tools": [
    {"id": "Git.Git", "name": "Git", "category": "Essentials"},
    {"id": "Microsoft.VisualStudioCode", "name": "VS Code", "category": "Essentials"}
  ]
}
```

### Full Development Environment
See `config.example.json` for a complete example with Visual Studio, Docker, Node.js, and more.

## What Gets Configured

1. **WinGet Packages**: All tools listed in your config file
2. **GitHub CLI**: Authenticated and ready to use
3. **GitHub Copilot CLI**: Extension installed automatically
4. **Oh My Posh**: Theme configured in your PowerShell profile
5. **Repository**: Cloned to your specified location

## Requirements

- Windows 10/11
- WinGet (Microsoft App Installer from Microsoft Store)
- PowerShell 5.1 or PowerShell 7+

## Tips

- Run as Administrator for best results
- Reboot after installation for WSL, Docker, and Visual Studio
- Restart your terminal to see the Oh My Posh theme
- The script is idempotent - it won't reinstall existing packages

## Contributing

This is designed to be forked and customized! 
1. Fork the repository
2. Create your own config file
3. Modify the script to add new features
4. Share your improvements!

## License

MIT License - Feel free to use and modify as needed.
