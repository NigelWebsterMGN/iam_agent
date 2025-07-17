param (
    [string]$cloudflare_domain,
    [string]$cloudflare_scoped_api,
    [string]$clientId,
    [switch]$silent,
    [switch]$uninstall,
    [string]$cloudflare_api_url = "https://api.cloudflare.com/client/v4"
)

function Reset-GlobalVars {
    $record = $null
    $dnsRecords = $null
    $tunnelMatch = $null
    $existingTunnels = $null
    $tunnelId = $null
    $zoneId = $null
    $tunnelList = $null
    $tunnelName = $null
}

Reset-GlobalVars

$ErrorActionPreference = "Stop"
$installDir = "C:\Program Files\iam_agent"
if (!(Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}
$nssmPath = "C:\nssm\win64\nssm.exe"
$logFile = "$installDir\install.log"
$setupFile = "$installDir\setup.json"
$listenerPath = "$installDir\listener.exe"
$listenerService = Get-Service -Name CloudflareTunnelListener -ErrorAction SilentlyContinue
$listenerExeUrl = "https://github.com/MGN-Consultancy/IAM-AGENT-PUBLIC/raw/d703f08808d36353605803e1f89a38a62cab1ba8/listener.exe"
$servicename = "CloudflareTunnelListener"

function Log($msg) {
    if (!(Test-Path $logFile)) { New-Item -ItemType File -Path $logFile -Force | Out-Null }
    Add-Content -Path $logFile -Value "$(Get-Date -Format o): $msg"
    if (-not $silent) { Write-Host $msg }
}

function Test-FileSystemPermissions($path) {
    try {
        $testFile = Join-Path $path "test_permissions.tmp"
        "test" | Out-File -FilePath $testFile -Force
        if (Test-Path $testFile) {
            Remove-Item $testFile -Force
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Get-DiagnosticInfo {
    Log "=== DIAGNOSTIC INFORMATION ==="
    Log "PowerShell Version: $($PSVersionTable.PSVersion)"
    Log "Current User: $env:USERNAME"
    Log "Current Directory: $(Get-Location)"
    Log "Install Directory: $installDir"
    Log "Install Directory Exists: $(Test-Path $installDir)"
    Log "Setup File Path: $setupFile"
    Log "Log File Path: $logFile"
    Log "Execution Policy: $(Get-ExecutionPolicy)"
    Log "Running as Admin: $(([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator'))"
    Log "File System Permissions: $(Test-FileSystemPermissions $installDir)"
    Log "=============================="
}

if ($uninstall) {
Log "Uninstall requested. Stopping services..."
Stop-Service CloudflareTunnelListener -ErrorAction SilentlyContinue

$listenerExists = Get-Service -Name CloudflareTunnelListener -ErrorAction SilentlyContinue
if ($null -ne $listenerExists) {
    & $nssmPath remove CloudflareTunnelListener confirm
    Log "Removed CloudflareTunnelListener service."
} else {
    Log "CloudflareTunnelListener service not found. Skipping removal."
}

    Stop-Service "Cloudflare Tunnel" -ErrorAction SilentlyContinue

    if (Test-Path $cloudflaredPath) {
        Log "Uninstalling Cloudflared service..."
        Start-Process -FilePath $cloudflaredPath -ArgumentList "service uninstall" -NoNewWindow -Wait -RedirectStandardOutput "$installDir\cloudflared-out.log" -RedirectStandardError "$installDir\cloudflared-err.log"
    }
    sc.exe delete Cloudflared | Out-Null
    if (-not (Get-Service -Name "Cloudflared" -ErrorAction SilentlyContinue)) {
        Remove-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\Cloudflared" -Force -ErrorAction SilentlyContinue
    }

    if (-not $silent) {
        try {
            $cloudflare_domain = Read-Host "Enter Cloudflare domain"
            $cloudflare_scoped_api = Read-Host "Enter Cloudflare API token"
            $accountRes = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
            $matchingAccount = $accountRes.result | Where-Object { $_.name -match [regex]::Escape($cloudflare_domain) } | Select-Object -First 1
            if ($null -ne $matchingAccount) {
                $accountId = $matchingAccount.id
            } elseif ($accountRes.result.Count -eq 1) {
                $accountId = $accountRes.result[0].id
            } else {
                throw "Unable to determine Cloudflare account for domain '$cloudflare_domain'."
            }

            $zoneRes = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/zones?name=$cloudflare_domain" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
            $zoneId = $zoneRes.result[0].id

            $tunnelList = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
            $tunnelMatch = $tunnelList.result | Where-Object { $_.name -eq $tunnelName -and $_.deleted_at -eq $null }

            if ($tunnelMatch) {
                $tunnelId = $tunnelMatch.id
                $deleteTunnel = Read-Host "Do you want to delete the Cloudflare tunnel and DNS record? (Y/N)"
                if ($deleteTunnel -in @('Y', 'y')) {
                    Log "Cleaning up tunnel sessions..."
                    & $cloudflaredPath tunnel cleanup $tunnelId | Out-Null

                    Log "Deleting Cloudflare tunnel..."
                    & $cloudflaredPath tunnel delete -f $tunnelId | Out-Null

                    Log "Deleting DNS record..."
                    $dnsRecords = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/zones/$zoneId/dns_records?type=CNAME&name=$dnsName" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
                    $record = $dnsRecords.result | Where-Object { $_.name -eq $dnsName }
                    if ($record) {
                        Invoke-RestMethod -Method DELETE -Uri "$cloudflare_api_url/zones/$zoneId/dns_records/$($record.id)" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
                        Log "DNS record deleted."
                    }
                }
            }
        } catch {
            Log "Cloudflare tunnel cleanup failed: $_"
        }
    }

    Remove-Item "$installDir" -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

function Get-MachineId {
    try {
        $uuid = (Get-WmiObject -Class Win32_ComputerSystemProduct).UUID
        if ($uuid -and $uuid -ne 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF') {
            return $uuid
        } else {
            return (Get-CimInstance Win32_BIOS).SerialNumber
        }
    } catch {
        return (Get-Date).Ticks
    }
}

if (-not $silent) {
    if (-not $cloudflare_domain) { $cloudflare_domain = Read-Host "Enter Cloudflare domain" }
    if (-not $cloudflare_scoped_api) { $cloudflare_scoped_api = Read-Host "Enter Cloudflare API token" }
    if (-not $clientId) { $clientId = Read-Host "Enter client ID" }
}

$machineId = Get-MachineId
$machinename = $env:COMPUTERNAME
$tunnelName = "iam-agent-$clientId-$machineId"
$dnsName = "$tunnelName.$cloudflare_domain"
$tunnelTokenPath = "$installDir\tunnel_token.txt"
$skipCloudflaredSetup = $false

# === VALIDATION: Ensure all required variables are set ===
Log "Validating required parameters..."
$validationErrors = @()

if (-not $cloudflare_domain) { $validationErrors += "cloudflare_domain is required" }
if (-not $cloudflare_scoped_api) { $validationErrors += "cloudflare_scoped_api is required" }
if (-not $clientId) { $validationErrors += "clientId is required" }
if (-not $machineId) { $validationErrors += "machineId could not be determined" }
if (-not $machinename) { $validationErrors += "machinename could not be determined" }

if ($validationErrors.Count -gt 0) {
    Log "VALIDATION ERRORS FOUND:"
    foreach ($error in $validationErrors) {
        Log "- $error"
    }
    throw "Script cannot continue with missing required parameters"
}

Log "Validation successful. Proceeding with setup..."
Log "- Cloudflare domain: $cloudflare_domain"
Log "- Client ID: $clientId"
Log "- Machine ID: $machineId"
Log "- Machine name: $machinename"
Log "- Tunnel name: $tunnelName"
Log "- DNS name: $dnsName"

Log "Getting account and zone ID..."
try {
    $accountRes = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
    $matchingAccount = $accountRes.result | Where-Object { $_.name -match [regex]::Escape($cloudflare_domain) } | Select-Object -First 1
    if ($null -ne $matchingAccount) {
        $accountId = $matchingAccount.id
    } elseif ($accountRes.result.Count -eq 1) {
        $accountId = $accountRes.result[0].id
    } else {
        throw "Unable to determine Cloudflare account for domain '$cloudflare_domain'."
    }
    Log "Using Cloudflare account ID: $accountId"
} catch {
    throw "Failed to retrieve Cloudflare account ID: $_"
}

try {
    $zoneRes = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/zones?name=$cloudflare_domain" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
    if (-not $zoneRes.result -or $zoneRes.result.Count -eq 0) {
        throw "No zones found for domain $cloudflare_domain"
    }
    $zoneId = $zoneRes.result[0].id
    Log "Retrieved Zone ID: $zoneId"
} catch {
    throw "Failed to retrieve Zone ID: $_"
}

try {
    $tunnelList = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
    $tunnelMatch = $tunnelList.result | Where-Object { $_.name -eq $tunnelName -and $_.deleted_at -eq $null }
    Log "Checked for existing tunnel named $tunnelName"
} catch {
    throw "Failed to retrieve existing tunnels: $_"
}

if ($tunnelMatch) {
    $tunnelId = $tunnelMatch.id
    if ($silent) {
        Log "Tunnel exists and silent mode active. Aborting install to avoid prompts."
        exit 0
    }
    Write-Host "Tunnel '$tunnelName' exists."
    $regen = Read-Host "Fetch token for existing tunnel? (Y/N)"
    if ($regen -eq 'Y' -or $regen -eq 'y') {
        $tokenRes = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel/$tunnelId/token" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
        $tunnelToken = $tokenRes.result
        Set-Content -Path $tunnelTokenPath -Value $tunnelToken
        Log "Tunnel token obtained and logged."
    } else {
        Log "Using existing tunnel without regenerating token."
        if (Test-Path $tunnelTokenPath) {
            $tunnelToken = Get-Content -Path $tunnelTokenPath -ErrorAction SilentlyContinue
        } elseif (-not $silent) {
            $tunnelToken = Read-Host "Tunnel token file not found. Please paste the existing Cloudflare tunnel token"
            Set-Content -Path $tunnelTokenPath -Value $tunnelToken
            Log "Manual token entered and saved to file."
        } else {
            throw "Tunnel token not found and silent mode is enabled. Cannot proceed."
        }
    }

    if ($tunnelMatch.status -eq "healthy") {
        $reinstall = Read-Host "Tunnel is currently healthy. Reinstall Cloudflared anyway? (Y/N)"
        if ($reinstall -notin @('Y', 'y')) {
            Log "Tunnel is healthy. Skipping Cloudflared reinstall."
            $skipCloudflaredSetup = $true
        }
    }
} else {
    try {
        Log "Creating new tunnel: $tunnelName"
        $tunnelBody = @{ name = $tunnelName }
        $tunnelBodyJson = $tunnelBody | ConvertTo-Json -Depth 5
        $tunnelRes = Invoke-RestMethod -Method POST -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" } -Body $tunnelBodyJson
        $tunnelId = $tunnelRes.result.id
        $tunnelToken = $tunnelRes.result.token
        Set-Content -Path $tunnelTokenPath -Value $tunnelToken
        Log "New tunnel created. Tunnel ID: $tunnelId"
    } catch {
        throw "Failed to create new Cloudflare tunnel: $_"
    }
}

# === Cloudflare Tunnel Application and DNS Setup ===
# Always set up ingress and DNS, even if they exist
try {
    # Fetch tunnel ID if not already set
    if (-not $tunnelId) {
        $tunnelList = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
        $tunnelMatch = $tunnelList.result | Where-Object { $_.name -eq $tunnelName -and $_.deleted_at -eq $null }
        if ($tunnelMatch) {
            $tunnelId = $tunnelMatch.id
        } else {
            throw "Tunnel not found after creation."
        }
    }
    Log "Completed creating tunnel. Tunnel ID: $tunnelId"

    # Construct DNS name
    $tunneldns = "$tunnelName.$cloudflare_domain"

    # Always create/update application ingress rule
    $ingressConfig = @{
        config = @{
            ingress = @(
                @{ hostname = $tunneldns; service = "http://localhost:3030"; originRequest = @{} },
                @{ service = "http_status:404" }
            )
        }
    } | ConvertTo-Json -Depth 6
    $configUrl = "$cloudflare_api_url/accounts/$accountId/cfd_tunnel/$tunnelId/configurations"
    $configRes = Invoke-RestMethod -Method PUT -Uri $configUrl -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" } -Body $ingressConfig
    Log "Completed application rule for tunnel $tunnelId."

    # Create or update DNS record
    $dnsBody = @{
        type = "CNAME"
        proxied = $true
        name = $tunneldns
        content = "$tunnelId.cfargotunnel.com"
    } | ConvertTo-Json -Depth 4
    $dnsUrl = "$cloudflare_api_url/zones/$zoneId/dns_records"
    # Check if DNS record exists
    $existingDns = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/zones/$zoneId/dns_records?type=CNAME&name=$tunneldns" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
    if ($existingDns.result.Count -gt 0) {
        $recordId = $existingDns.result[0].id
        $updateDnsUrl = "$cloudflare_api_url/zones/$zoneId/dns_records/$recordId"
        $dnsRes = Invoke-RestMethod -Method PUT -Uri $updateDnsUrl -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" } -Body $dnsBody
        Log "Updated DNS record for $tunneldns -> $tunnelId.cfargotunnel.com."
    } else {
        $dnsRes = Invoke-RestMethod -Method POST -Uri $dnsUrl -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" } -Body $dnsBody
        Log "Created DNS record for $tunneldns -> $tunnelId.cfargotunnel.com."
    }
} catch {
    Log "Error during tunnel application/DNS setup: $_"
    throw $_
}

if (-not $skipCloudflaredSetup) {
    $cloudflaredPath = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
    if (!(Test-Path $cloudflaredPath)) {
        $msiPath = "$env:TEMP\cloudflared.msi"
        Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi" -OutFile $msiPath
        Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait
    } else {
        $cloudflareService = Get-Service -Name "Cloudflared agent" -ErrorAction SilentlyContinue
        if ($cloudflareService) {
            Stop-Service -Name "Cloudflared agent" -Force -ErrorAction SilentlyContinue
            Start-Process -FilePath $cloudflaredPath -ArgumentList "service uninstall" -Wait
            Log "Cloudflared Tunnel Uninstalled"
        }
    }

    Start-Process -FilePath $cloudflaredPath -ArgumentList "service install $tunnelToken" -Wait
    Log "Cloudflared Tunnel Reinstalled, Checking Status"
    $tunnelcurrentstatus = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel/$tunnelId" -Headers @{ Authorization = "Bearer $cloudflare_scoped_api"; "Content-Type" = "application/json" }
    $status = $tunnelcurrentstatus.result.status
    Log "Cloudflared Tunnel has the following status '$status'"
}


# Installing the Listner Service

# Download listener if missing
log "Checking for existing installations of the listener"

if (-not (Test-Path $listenerPath)) {
    log "Downloading listener.exe..."
    Invoke-WebRequest -Uri $listenerExeUrl -OutFile $listenerPath
}


if ($listenerService -and $listenerService.Status -eq 'Running') {
    $reinstallListener = Read-Host "Listener service is already running. Reinstall listener? (Y/N)"
    if ($reinstallListener -in @('Y', 'y')) {
        Stop-Service -Name CloudflareTunnelListener -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        log "Reinstalling the listener"
       # Remove old broken service
        $existing = (sc.exe qc $serviceName 2>&1 | Select-String "BINARY_PATH_NAME" | ForEach-Object { ($_ -split " : ")[1].Trim('"') }) -join ""
        if ($existing -like "*nssm.exe*") {
        log "Removing Listener service..."
        & $nssmPath remove $serviceName confirm
        start-sleep -seconds 2

          # === Install the service using cmd.exe to avoid argument issues ===
        log "Re-installing the Listener Service"
        $cmd = "$nssmPath install $serviceName `"$listenerPath`"" 
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -Wait


        # Set service parameters
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "AppParameters", "--service" -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "AppDirectory", $installDir -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "AppStdout", "$installDir\listener_stdout.log" -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "AppStderr", "$installDir\listener_stderr.log" -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "Start", "SERVICE_AUTO_START" -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "start", $serviceName -Wait

        # Final confirmation
        Start-Sleep -Seconds 1
        Log "Installed listener service '$serviceName' from $listenerPath"
        sc.exe qc $serviceName
        Log "Listener installed and started."
}
    } else {
        Log "Listener service running. Skipping reinstall."
    }



} else {

           # === Install the service using cmd.exe to avoid argument issues ===
        $cmd = "$nssmPath install $serviceName `"$listenerPath`"" 
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -Wait


        # Set service parameters
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "AppParameters", "--service" -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "AppDirectory", $installDir -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "AppStdout", "$installDir\listener_stdout.log" -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "AppStderr", "$installDir\listener_stderr.log" -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "set", $serviceName, "Start", "SERVICE_AUTO_START" -Wait
        Start-Process -FilePath $nssmPath -ArgumentList "start", $serviceName -Wait

        # Final confirmation
        Start-Sleep -Seconds 1
        Log "Installed listener service '$serviceName' from $listenerPath"
        sc.exe qc $serviceName
        Log "Listener installed and started."
}

# === CRITICAL: Create setup.json file ===
try {
    Log "Creating setup.json configuration file..."
    
    # Early diagnostics before file creation
    Log "Pre-creation diagnostics:"
    Log "- tunnelName: $tunnelName"
    Log "- machinename: $machinename"
    Log "- clientId: $clientId"
    Log "- setupFile path: $setupFile"
    Log "- installDir exists: $(Test-Path $installDir)"
    
    # Generate magic word
    $magicWord = [guid]::NewGuid().ToString()
    Log "Generated magic word: $($magicWord.Substring(0, 8))..."
    
    # Create setup configuration
    $setup = @{ 
        tunnelName = $tunnelName
        machineName = $machinename
        clientId = $clientId
        magicWord = $magicWord
        magicwordset = "False"
    } | ConvertTo-Json -Depth 5
    
    # Ensure directory exists
    if (!(Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        Log "Created installation directory: $installDir"
    }
    
    # Write setup file with error handling
    $setup | Set-Content -Path $setupFile -Encoding utf8 -ErrorAction Stop
    
    # Verify file was created successfully
    if (Test-Path $setupFile) {
        $fileSize = (Get-Item $setupFile).Length
        Log "Setup.json file created successfully at: $setupFile (Size: $fileSize bytes)"
        
        # Verify file content is valid JSON
        try {
            $testRead = Get-Content -Path $setupFile -Raw | ConvertFrom-Json
            if ($testRead.magicWord -eq $magicWord) {
                Log "Setup.json file validation successful - magic word matches"
            } else {
                throw "Setup.json validation failed - magic word mismatch"
            }
        } catch {
            throw "Setup.json file is not valid JSON: $_"
        }
    } else {
        throw "Setup.json file was not created at expected location: $setupFile"
    }
    
    Log "Setup complete. Tunnel and listener are now installed."
    Log "Magic word saved for secure communications, This will be imported by the web front end on first run and all future communications must include the magicword in additon to API key"
    
} catch {
    Log "CRITICAL ERROR: Failed to create setup.json file: $_"
    Log "Setup.json creation failed at: $setupFile"
    Log "This is a critical component - the node will not function without this file"
    
    # Additional diagnostic information
    Show-DiagnosticInfo
    
    # Try to create the file again with more verbose error handling
    try {
        Log "Attempting to create setup.json file again..."
        
        # Try creating just the directory first
        if (!(Test-Path $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force -ErrorAction Stop | Out-Null
        }
        
        # Try a simpler approach to file creation
        $setupJson = @"
{
    "tunnelName": "$tunnelName",
    "machineName": "$machinename",
    "clientId": "$clientId",
    "magicWord": "$magicWord",
    "magicwordset": "False"
}
"@
        
        [System.IO.File]::WriteAllText($setupFile, $setupJson, [System.Text.Encoding]::UTF8)
        
        if (Test-Path $setupFile) {
            Log "Setup.json file created successfully on retry"
        } else {
            Log "Setup.json file creation failed on retry"
        }
        
    } catch {
        Log "Retry attempt also failed: $_"
        Log "SCRIPT WILL EXIT - Node setup incomplete without setup.json file"
        throw "Critical setup.json file creation failed: $_"
    }
}

# === FINAL VALIDATION ===
Log "Performing final validation..."
if (Test-Path $setupFile) {
    try {
        $finalValidation = Get-Content -Path $setupFile -Raw | ConvertFrom-Json
        if ($finalValidation.magicWord -and $finalValidation.tunnelName -and $finalValidation.clientId) {
            Log "SUCCESS: Setup.json file validated successfully"
            Log "Final setup.json contains:"
            Log "- Tunnel Name: $($finalValidation.tunnelName)"
            Log "- Machine Name: $($finalValidation.machineName)"
            Log "- Client ID: $($finalValidation.clientId)"
            Log "- Magic Word: $($finalValidation.magicWord.Substring(0, 8))..."
            Log "- Magic Word Set: $($finalValidation.magicwordset)"
        } else {
            throw "Setup.json file is missing required fields"
        }
    } catch {
        Log "CRITICAL ERROR: Setup.json file validation failed: $_"
        throw "Final validation failed: $_"
    }
} else {
    Log "CRITICAL ERROR: Setup.json file does not exist at: $setupFile"
    throw "Setup.json file was not created - node will not function"
}

Log "========================================="
Log "SETUP COMPLETED SUCCESSFULLY"
Log "Node is ready for operation"
Log "========================================="
