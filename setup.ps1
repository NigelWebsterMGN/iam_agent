param (
    [string]$cloudflare_domain,
    [string]$cloudflare_scoped_api,
    [string]$clientId,
    [switch]$silent,
    [switch]$uninstall,
    [string]$cloudflare_api_url = "https://api.cloudflare.com/client/v4"
)

$ErrorActionPreference = "Stop"
$installDir = "C:\Program Files\iam_agent"
$nssmPath = "C:\nssm\win64\nssm.exe"
$cloudflaredUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
$listenerExeUrl = "https://raw.githubusercontent.com/nigelwebsterMGN/iam_agent/main/listener.exe"
$logFile = "$installDir\install.log"

function Log($msg) {
    if (-not $silent) { Write-Host $msg }
    Add-Content -Path $logFile -Value "$(Get-Date -Format o): $msg"
}

if ($uninstall) {
    Log "Uninstall requested. Stopping services..."

    Stop-Service CloudflareTunnelListener -ErrorAction SilentlyContinue
    & $nssmPath remove CloudflareTunnelListener confirm

    Stop-Service cloudflared -ErrorAction SilentlyContinue
    & $nssmPath remove cloudflared confirm

    Log "Uninstallation complete."

    # Clean up after logging
    Remove-Item "$installDir" -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}


if (!(Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
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

$machineId = Get-MachineId
$tunnelName = "agent-$clientId-$machineId"
$dnsName = "$tunnelName.$cloudflare_domain"

Log "Getting account ID..."
$accountRes = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts" -Headers @{
    Authorization = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
}
$accountId = ($accountRes.result | Where-Object { $_.name -like "*$cloudflare_domain*" }).id

Log "Getting zone ID..."
$zoneRes = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/zones?name=$cloudflare_domain" -Headers @{
    Authorization = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
}
$zoneId = $zoneRes.result[0].id

Log "Checking for existing tunnels..."
$tunnelList = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel" -Headers @{
    Authorization = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
}
$tunnelMatch = $tunnelList.result | Where-Object { $_.name -eq $tunnelName }
foreach ($t in $tunnelMatch) {
    Log "Deleting tunnel ID: $($t.id)..."
    Invoke-RestMethod -Method DELETE -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel/$($t.id)" -Headers @{
        Authorization = "Bearer $cloudflare_scoped_api"
        "Content-Type" = "application/json"
    }
    Start-Sleep -Seconds 2
}

Log "Creating new tunnel..."
$tunnelBody = @{ name = $tunnelName } | ConvertTo-Json -Compress
$tunnelRes = Invoke-RestMethod -Method POST -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel" -Headers @{
    Authorization = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
} -Body $tunnelBody
$tunnelId = $tunnelRes.result.id
$tunnelToken = $tunnelRes.result.token
$tunnelTarget = "$tunnelId.cfargotunnel.com"

Log "Checking existing DNS..."
$dnsRecords = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/zones/$zoneId/dns_records?type=CNAME&name=$dnsName" -Headers @{
    Authorization = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
}
if ($dnsRecords.result.Count -gt 0) {
    $record = $dnsRecords.result[0]
    if ($record.content -ne $tunnelTarget) {
        Log "Updating DNS record to correct tunnel target..."
        Invoke-RestMethod -Method DELETE -Uri "$cloudflare_api_url/zones/$zoneId/dns_records/$($record.id)" -Headers @{
            Authorization = "Bearer $cloudflare_scoped_api"
            "Content-Type" = "application/json"
        }
    } else {
        Log "DNS record already correct. Skipping DNS creation."
    }
}
if ($null -eq $record -or $record.content -ne $tunnelTarget) {
    $dnsBody = @{
        type = "CNAME"
        name = $dnsName
        content = $tunnelTarget
        proxied = $true
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method POST -Uri "$cloudflare_api_url/zones/$zoneId/dns_records" -Headers @{
        Authorization = "Bearer $cloudflare_scoped_api"
        "Content-Type" = "application/json"
    } -Body $dnsBody
    Log "DNS CNAME created or updated."
}

$cloudflaredPath = "$installDir\cloudflared.exe"
Invoke-WebRequest -Uri $cloudflaredUrl -OutFile $cloudflaredPath
Start-Process -FilePath $cloudflaredPath -ArgumentList "service install $tunnelToken" -Wait
Start-Process -FilePath $cloudflaredPath -ArgumentList "service run" -Wait
Log "cloudflared installed and running."

$listenerPath = "$installDir\listener.exe"
Invoke-WebRequest -Uri $listenerExeUrl -OutFile $listenerPath
& $nssmPath install CloudflareTunnelListener "$listenerPath --service"
& $nssmPath start CloudflareTunnelListener
Log "Listener installed and started."

Log "Agent install complete. Access: https://$dnsName/run-command"

