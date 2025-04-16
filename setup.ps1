param (
    [string]$cloudflare_domain,
    [string]$cloudflare_scoped_api,
    [string]$clientId,
    [string]$cloudflare_api_url = "https://api.cloudflare.com/client/v4"
)

$ErrorActionPreference = "Stop"
$installDir = "C:\Program Files\iam_agent"
$nssmPath = "C:\nssm\win64\nssm.exe"
$listenerExeUrl = "https://raw.githubusercontent.com/nigelwebsterMGN/iam_agent/main/listener.exe"
$cloudflaredUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"

# Create install folder
if (!(Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }

# -------------------- Get Machine ID --------------------
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

# -------------------- Get Account ID --------------------
$accountRes = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/accounts" -Headers @{
    "Authorization" = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
}
$accountId = ($accountRes.result | Where-Object { $_.name -like "*$cloudflare_domain*" }).id

# -------------------- Get Zone ID --------------------
$zoneRes = Invoke-RestMethod -Method GET -Uri "$cloudflare_api_url/zones?name=$cloudflare_domain" -Headers @{
    "Authorization" = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
}
$zoneId = $zoneRes.result[0].id

# -------------------- Create Tunnel --------------------
$tunnelBody = @{ name = $tunnelName } | ConvertTo-Json -Compress
$tunnelRes = Invoke-RestMethod -Method POST -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel" -Headers @{
    "Authorization" = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
} -Body $tunnelBody
$tunnelId = $tunnelRes.result.id

# -------------------- Get Tunnel Token --------------------
$tokenRes = Invoke-RestMethod -Method POST -Uri "$cloudflare_api_url/accounts/$accountId/cfd_tunnel/$tunnelId/token" -Headers @{
    "Authorization" = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
}
$tunnelToken = $tokenRes.result.token

# -------------------- Create DNS Record --------------------
$subdomain = "$tunnelName.$cloudflare_domain"
$dnsBody = @{
    type = "CNAME"
    name = $subdomain
    content = "$tunnelId.cfargotunnel.com"
    proxied = $true
} | ConvertTo-Json -Compress

Invoke-RestMethod -Method POST -Uri "$cloudflare_api_url/zones/$zoneId/dns_records" -Headers @{
    "Authorization" = "Bearer $cloudflare_scoped_api"
    "Content-Type" = "application/json"
} -Body $dnsBody

# -------------------- Install cloudflared --------------------
$cloudflaredPath = "$installDir\cloudflared.exe"
Invoke-WebRequest -Uri $cloudflaredUrl -OutFile $cloudflaredPath
Start-Process -FilePath $cloudflaredPath -ArgumentList "service install $tunnelToken" -Wait
Start-Process -FilePath $cloudflaredPath -ArgumentList "service run" -Wait

# -------------------- Download listener.exe --------------------
$listenerPath = "$installDir\listener.exe"
Invoke-WebRequest -Uri $listenerExeUrl -OutFile $listenerPath

# -------------------- Register listener as a service --------------------
& $nssmPath install CloudflareTunnelListener $listenerPath
& $nssmPath start CloudflareTunnelListener

# -------------------- Done --------------------
Write-Host "`n✅ Agent installed successfully."
Write-Host "🔐 Tunnel: $tunnelName"
Write-Host "🌐 Access URL: https://$subdomain/run-command"
