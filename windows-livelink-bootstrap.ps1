# Windows Firewall Configuration Script
# Configure outbound SQL connections and inbound ports 3551, 3552, and ping
# Also configures Puppet and sets timezone to Australia/Sydney

# Set execution policy to allow remote scripts
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

# Run as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script requires Administrator privileges. Please run as Administrator."
    exit 1
}

# Set timezone to Australia/Sydney
Write-Host "Checking timezone..." -ForegroundColor Yellow
try {
    $currentTimezone = Get-TimeZone -ErrorAction Stop
    if ($currentTimezone.Id -eq "AUS Eastern Standard Time") {
        Write-Host "Timezone is already set to Australia/Sydney" -ForegroundColor Green
    } else {
        Write-Host "Setting timezone to Australia/Sydney..." -ForegroundColor Yellow
        Set-TimeZone -Id "AUS Eastern Standard Time" -ErrorAction Stop
        Write-Host "Timezone set to Australia/Sydney successfully" -ForegroundColor Green
    }
} catch {
    Write-Host "Warning: Could not check/set timezone. Error: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Puppet Configuration
Write-Host "`nChecking Puppet Configuration..." -ForegroundColor Yellow

# Check current Puppet configuration
$puppetConfigPath = "C:\ProgramData\PuppetLabs\puppet\etc\puppet.conf"
$currentHostname = $env:COMPUTERNAME
$currentCertname = $null
$currentServer = $null

if (Test-Path $puppetConfigPath) {
    Write-Host "Found existing puppet.conf" -ForegroundColor Cyan
    try {
        $puppetConfig = Get-Content $puppetConfigPath -Raw
        if ($puppetConfig -match 'certname\s*=\s*(.+)') {
            $currentCertname = $matches[1].Trim()
        }
        if ($puppetConfig -match 'server\s*=\s*(.+)') {
            $currentServer = $matches[1].Trim()
        }
        
        Write-Host "Current Puppet certname: $currentCertname" -ForegroundColor Cyan
        Write-Host "Current Puppet server: $currentServer" -ForegroundColor Cyan
    } catch {
        Write-Host "Could not read existing puppet.conf" -ForegroundColor Yellow
    }
} else {
    Write-Host "No existing puppet.conf found" -ForegroundColor Yellow
}

Write-Host "Current Windows hostname: $currentHostname" -ForegroundColor Cyan

# Ask user what to do
if ($currentCertname -and $currentServer) {
    Write-Host "`nCurrent Puppet configuration found:" -ForegroundColor Green
    Write-Host "  Certname: $currentCertname" -ForegroundColor White
    Write-Host "  Server: $currentServer" -ForegroundColor White
    Write-Host "  Windows hostname: $currentHostname" -ForegroundColor White
    $puppetChoice = Read-Host "`nDo you want to keep current config (k), reconfigure (r), or cancel (c)?"
} else {
    $puppetChoice = Read-Host "`nNo valid Puppet config found. Configure Puppet (y) or cancel (c)?"
}

if ($puppetChoice -eq 'k' -or $puppetChoice -eq 'K') {
    Write-Host "Keeping current Puppet configuration." -ForegroundColor Green
    # Use current hostname
    $windowsHostname = $currentHostname
    Write-Host "Using current hostname: $windowsHostname" -ForegroundColor Cyan
} elseif ($puppetChoice -eq 'c' -or $puppetChoice -eq 'C') {
    Write-Host "Script cancelled." -ForegroundColor Yellow
    exit 0
} else {
    # Proceed with Puppet configuration (r for reconfigure, y for new config)
    Write-Host "Configuring Puppet..." -ForegroundColor Yellow
    
    # Prompt user for certname
    $certname = Read-Host "Enter the hostname only for puppet cert eg: liq-01.customername"

    # Convert certname to valid Windows hostname (replace dots with dashes)
    $windowsHostname = $certname -replace '\.', '-'

# Function to validate and clean hostname
function ValidateHostname($hostname) {
    # Remove invalid characters (only allow letters, numbers, and hyphens)
    $cleanHostname = $hostname -replace '[^a-zA-Z0-9\-]', ''
    
    # Ensure it doesn't start or end with hyphen
    $cleanHostname = $cleanHostname -replace '^-+|-+$', ''
    
    # Truncate if too long
    if ($cleanHostname.Length -gt 15) {
        $cleanHostname = $cleanHostname.Substring(0,15)
        # Remove trailing hyphen if truncation created one
        $cleanHostname = $cleanHostname -replace '-+$', ''
    }
    
    return $cleanHostname
}

# Validate and clean hostname
$originalHostname = $windowsHostname
$windowsHostname = ValidateHostname $windowsHostname

# Show warnings if hostname was modified
if ($originalHostname -ne $windowsHostname) {
    Write-Host "Warning: Hostname was cleaned/modified from '$originalHostname' to '$windowsHostname'" -ForegroundColor Yellow
}

# Validate and show hostname preview
$previewHostname = $windowsHostname
if ($originalHostname.Length -gt 15) {
    Write-Host "Warning: Original hostname was longer than 15 characters and was truncated." -ForegroundColor Yellow
}

Write-Host "Certname: $certname.pcms.local" -ForegroundColor Cyan
Write-Host "Windows hostname will be set to: $previewHostname" -ForegroundColor Cyan

# Confirm hostname with user
$hostnameChoice = Read-Host "Are you happy with this hostname? Remember Windows has a 15 character limit so it might look weird. (y/n/c for custom)"
if ($hostnameChoice -eq 'c' -or $hostnameChoice -eq 'C') {
    # Custom hostname option
    Write-Host "Enter a custom Windows hostname:" -ForegroundColor Yellow
    $customHostname = Read-Host "Custom hostname (15 characters max, letters/numbers/hyphens only)"
    
    # Validate and clean custom hostname
    $originalCustom = $customHostname
    $customHostname = ValidateHostname $customHostname
    
    # Show warnings if custom hostname was modified
    if ($originalCustom -ne $customHostname) {
        Write-Host "Warning: Custom hostname was cleaned/modified from '$originalCustom' to '$customHostname'" -ForegroundColor Yellow
    }
    
    $windowsHostname = $customHostname
    Write-Host "Windows hostname will be set to: $windowsHostname" -ForegroundColor Cyan
    
    $finalChoice = Read-Host "Confirm this custom hostname? (y/n)"
    if ($finalChoice -ne 'y' -and $finalChoice -ne 'Y') {
        Write-Host "Script cancelled. Please run again." -ForegroundColor Yellow
        exit 0
    }
} elseif ($hostnameChoice -ne 'y' -and $hostnameChoice -ne 'Y') {
    Write-Host "Script cancelled. Please run again with a different certname." -ForegroundColor Yellow
    exit 0
}

    # Define directory and file paths
    $dirPath = "C:\ProgramData\PuppetLabs\puppet\etc"
    $filePath = Join-Path $dirPath "puppet.conf"

    # Check if file exists
    if (Test-Path -Path $filePath) {
        $choice = Read-Host "The file '$filePath' already exists. Overwrite? (y/n)"
        if ($choice -ne 'y') {
            Write-Host "Puppet configuration skipped."
        } else {
            # Ensure directory exists
            if (-not (Test-Path -Path $dirPath)) {
                New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
            }

            # Create puppet.conf with user input
            Set-Content -Path $filePath -Value @"
[main]
certname = $certname.pcms.local
server = puppet.prontocloud.io
[agent]
server = puppet.prontocloud.io
"@
            Write-Host "puppet.conf created at $filePath with certname '$certname.pcms.local'" -ForegroundColor Green
        }
    } else {
        # Ensure directory exists
        if (-not (Test-Path -Path $dirPath)) {
            New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        }

        # Create puppet.conf with user input
        Set-Content -Path $filePath -Value @"
[main]
certname = $certname.pcms.local
server = puppet.prontocloud.io
[agent]
server = puppet.prontocloud.io
"@
        Write-Host "puppet.conf created at $filePath with certname '$certname.pcms.local'" -ForegroundColor Green
    }
}

# Update Windows Computer Name/Hostname
Write-Host "`nChecking Windows hostname..." -ForegroundColor Yellow

# Get current computer name
$currentHostname = $env:COMPUTERNAME
Write-Host "Current hostname: $currentHostname" -ForegroundColor Cyan
Write-Host "Target hostname: $windowsHostname" -ForegroundColor Cyan

# Check if hostname change is needed
if ($currentHostname -eq $windowsHostname) {
    Write-Host "`nHostname is already correct!" -ForegroundColor Green
    $hostnameChangeChoice = Read-Host "Hostname '$currentHostname' matches target '$windowsHostname'. Keep current hostname (k) or force change anyway (f)?"
    
    if ($hostnameChangeChoice -eq 'k' -or $hostnameChangeChoice -eq 'S') {
        Write-Host "Hostname change skipped." -ForegroundColor Yellow
        $restartRequired = $false
    } else {
        # Force hostname change
        Write-Host "Forcing hostname change..." -ForegroundColor Yellow
        try {
            Rename-Computer -NewName $windowsHostname -Force -ErrorAction Stop
            Write-Host "Hostname successfully set to '$windowsHostname'. A restart will be required for the change to take effect." -ForegroundColor Green
            $restartRequired = $true
        } catch {
            Write-Host "Error: Could not change hostname. Error: $($_.Exception.Message)" -ForegroundColor Red
            $restartRequired = $false
        }
    }
} else {
    # Hostname needs to be changed
    Write-Host "`nHostname change needed: '$currentHostname' -> '$windowsHostname'" -ForegroundColor Yellow
    $hostnameChangeChoice = Read-Host "Change hostname from '$currentHostname' to '$windowsHostname'? (y/n)"
    
    if ($hostnameChangeChoice -eq 'y' -or $hostnameChangeChoice -eq 'Y') {
        try {
            # Update computer name (hostname already validated above)
            Write-Host "Setting hostname to '$windowsHostname'..." -ForegroundColor Yellow
            Rename-Computer -NewName $windowsHostname -Force -ErrorAction Stop
            Write-Host "Hostname successfully set to '$windowsHostname'. A restart will be required for the change to take effect." -ForegroundColor Green
            $restartRequired = $true
        } catch {
            Write-Host "Error: Could not change hostname. Error: $($_.Exception.Message)" -ForegroundColor Red
            $restartRequired = $false
        }
    } else {
        Write-Host "Hostname change skipped." -ForegroundColor Yellow
        $restartRequired = $false
    }
}

Write-Host "Configuring Windows Firewall rules..." -ForegroundColor Green

# Inbound rules
Write-Host "Creating inbound rules for ports 3551, 3552, and ping..." -ForegroundColor Yellow

# Define firewall rules to create
$firewallRules = @(
    @{
        DisplayName = "Inbound Port 3551 TCP"
        Protocol = "TCP"
        LocalPort = 3551
        Description = "Allow inbound TCP connections on port 3551"
    },
    @{
        DisplayName = "Inbound Port 3552 TCP"
        Protocol = "TCP"
        LocalPort = 3552
        Description = "Allow inbound TCP connections on port 3552"
    },
    @{
        DisplayName = "Inbound Ping"
        Protocol = "ICMPv4"
        IcmpType = 8
        Description = "Allow inbound ping (ICMP Echo Request)"
    },
    @{
        DisplayName = "Inbound Ping Reply"
        Protocol = "ICMPv4"
        IcmpType = 0
        Description = "Allow inbound ping replies (ICMP Echo Reply)"
    }
)

# Create firewall rules
foreach ($rule in $firewallRules) {
    if (-not (Get-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction SilentlyContinue)) {
        $params = @{
            DisplayName = $rule.DisplayName
            Direction = "Inbound"
            Protocol = $rule.Protocol
            Action = "Allow"
            Profile = "Any"
            Description = $rule.Description
        }
        
        # Add port-specific parameters
        if ($rule.LocalPort) {
            $params.LocalPort = $rule.LocalPort
            $params.RemotePort = "Any"
        }
        
        # Add ICMP-specific parameters
        if ($rule.ContainsKey('IcmpType')) {
            $params.IcmpType = $rule.IcmpType
        }
        
        New-NetFirewallRule @params
        Write-Host "Created $($rule.DisplayName) rule" -ForegroundColor Green
    } else {
        Write-Host "$($rule.DisplayName) rule already exists" -ForegroundColor Yellow
    }
}

Write-Host "Firewall rules configured successfully!" -ForegroundColor Green
Write-Host "Rules created:" -ForegroundColor Cyan
Write-Host "- Inbound connections on ports 3551 and 3552 (TCP only)" -ForegroundColor White
Write-Host "- Inbound ping (ICMP Echo Request/Reply)" -ForegroundColor White

# Optional: Display created rules
Write-Host "`nCreated firewall rules:" -ForegroundColor Yellow
Get-NetFirewallRule | Where-Object { $_.DisplayName -like "*Port 355*" -or $_.DisplayName -like "*Ping*" } | Format-Table DisplayName, Direction, Protocol, LocalPort, RemotePort, Action -AutoSize

# Install Windows Updates
Write-Host "`nWindows Updates..." -ForegroundColor Yellow
$updateChoice = Read-Host "Do you want to check and install Windows Updates? This may take a significant amount of time. (y/n)"

if ($updateChoice -eq 'y' -or $updateChoice -eq 'Y') {
    Write-Host "Installing Windows Updates..." -ForegroundColor Yellow
    Write-Host "This may take a significant amount of time depending on available updates..." -ForegroundColor Cyan
    try {
    # Check if PSWindowsUpdate module is available
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Host "Installing PSWindowsUpdate module..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop
        Install-Module -Name PSWindowsUpdate -Force -ErrorAction Stop
    }
    
    # Import the module
    Import-Module PSWindowsUpdate -ErrorAction Stop
    
    # Get available updates
    Write-Host "Checking for available updates..." -ForegroundColor Yellow
    $updates = Get-WUList -ErrorAction Stop
    
    if ($updates.Count -eq 0) {
        Write-Host "No updates available" -ForegroundColor Green
    } else {
        Write-Host "Found $($updates.Count) updates. Installing all updates..." -ForegroundColor Yellow
        # Install all updates automatically
        Install-WindowsUpdate -AcceptAll -AutoReboot:$false -ErrorAction Stop
        Write-Host "Windows Updates installed successfully" -ForegroundColor Green
    }
    } catch {
        Write-Host "Warning: Could not install Windows Updates. Error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "You may need to install updates manually through Windows Update." -ForegroundColor Yellow
    }
} else {
    Write-Host "Windows Updates skipped." -ForegroundColor Yellow
}

# Install .NET Framework 3.5 (this can take 10+ minutes)
Write-Host "`nChecking .NET Framework 3.5..." -ForegroundColor Yellow
try {
    $netfx3Status = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
    if ($netfx3Status.State -eq "Enabled") {
        Write-Host ".NET Framework 3.5 is already installed" -ForegroundColor Green
    } else {
        Write-Host "Installing .NET Framework 3.5..." -ForegroundColor Yellow
        Write-Host "This may take a while" -ForegroundColor Cyan
        Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop
        Write-Host ".NET Framework 3.5 installed successfully" -ForegroundColor Green
    }
} catch {
    Write-Host "Warning: Could not check/install .NET Framework 3.5. Error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "You may need to install this manually or ensure Windows Update is working." -ForegroundColor Yellow
}

# Final restart notification
if ($restartRequired) {
    Write-Host "`n" + "="*60 -ForegroundColor Red
    Write-Host "IMPORTANT: A RESTART IS REQUIRED" -ForegroundColor Red
    Write-Host "The hostname has been changed and requires a system restart to take effect." -ForegroundColor Yellow
    Write-Host "Please restart the computer when convenient." -ForegroundColor Yellow
    Write-Host "="*60 -ForegroundColor Red
    
    # Timeout prompt for restart (defaults to N after 30 seconds)
    Write-Host "`nWould you like to restart now? (y/n) [Defaults to 'n' in 30 seconds]" -ForegroundColor Yellow -NoNewline
    
    $timeout = 30
    $restartChoice = $null
    $startTime = Get-Date
    
    do {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Y' -or $key.KeyChar -eq 'y') {
                $restartChoice = 'y'
                Write-Host " y" -ForegroundColor Green
                break
            } elseif ($key.Key -eq 'N' -or $key.KeyChar -eq 'n') {
                $restartChoice = 'n'
                Write-Host " n" -ForegroundColor Green
                break
            }
        }
        
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -ge $timeout) {
            $restartChoice = 'n'
            Write-Host " n (timed out)" -ForegroundColor Yellow
            break
        }
        
        Start-Sleep -Milliseconds 100
    } while ($true)
    
    if ($restartChoice -eq 'y') {
        Write-Host "Restarting in 10 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    } else {
        Write-Host "Restart skipped. Please restart manually when convenient." -ForegroundColor Yellow
    }
}
