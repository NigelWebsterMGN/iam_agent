# Define the registry key path and service name
$regKey = "HKLM:\SOFTWARE\iam_automation"
$serviceName = "AzureRelayListener"

# Function to download a file from a URL to a destination path
function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )
    try {
        Write-Host "Downloading file from $Url to $Destination..."
        $client = New-Object System.Net.WebClient
        $client.DownloadFile($Url, $Destination)
        Write-Host "Download completed."
    }
    catch {
        Write-Host "Error downloading file: $_"
        exit 1
    }
}

# Prompt for installation directory (default: C:\program files\iam_agent)
$defaultInstallDir = "C:\program files\iam_agent"
$installDir = Read-Host "Enter installation directory for listener.exe (Default: $defaultInstallDir)"
if ([string]::IsNullOrWhiteSpace($installDir)) {
    $installDir = $defaultInstallDir
}

if (-not (Test-Path $installDir)) {
    Write-Host "Creating installation directory: $installDir"
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# Define the GitHub URL for listener.exe (update this URL as needed)
$listenerUrl = "https://raw.githubusercontent.com/nigelwebsterMGN/iam_agent/main/listener.exe"
$listenerExePath = Join-Path $installDir "listener.exe"

# Download listener.exe to the chosen installation directory
Download-File -Url $listenerUrl -Destination $listenerExePath

# Function to manage registry values
function Manage-RegistryValues {
    $values = @(
        @{ Name = "ns"; Prompt = "Enter value for your nameserver instance (e.g., namespace.servicebus.windows.net, no http://):" },
        @{ Name = "path"; Prompt = "Enter value for endpoint (This matches your endpoint name):" },
        @{ Name = "keyrule"; Prompt = "Enter value for keyrule (Usually 'default'):" },
        @{ Name = "primarykey"; Prompt = "Enter value for primarykey (Obtained from your endpoint in Azure):" },
        @{ Name = "secondarykey"; Prompt = "Enter value for secondarykey (Obtained from your endpoint in Azure):" }
    )

    if (Test-Path $regKey) {
        Write-Host "Registry key '$regKey' exists."
        $update = Read-Host "Do you want to update the registry values? (y/n)"
        if ($update -notlike "y") {
            Write-Host "Skipping registry updates."
            return $false
        }
    } else {
        Write-Host "Registry key '$regKey' does not exist. Creating it..."
        New-Item -Path $regKey -Force | Out-Null
    }

    foreach ($value in $values) {
        $existingValue = (Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue)."${($value.Name)}"
        if ($null -ne $existingValue) {
            Write-Host "Key '$($value.Name)' exists with value: $existingValue"
        }
        $newValue = Read-Host $value.Prompt
        Set-ItemProperty -Path $regKey -Name $value.Name -Value $newValue
        Write-Host "Key '$($value.Name)' set to '$newValue'."
    }

    Write-Host "Registry values have been updated successfully."
    return $true
}

# Function to manage the service, now using the installation directory's listener.exe
function Manage-Service {
    param(
         [string]$ListenerExePath
    )
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Write-Host "Service '$serviceName' already exists."
        $uninstall = Read-Host "Do you want to uninstall the service? (y/n)"
        if ($uninstall -like "y") {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            Remove-Service -Name $serviceName -ErrorAction SilentlyContinue
            Write-Host "Service '$serviceName' has been uninstalled."
            return $true
        } else {
            Write-Host "Service will remain installed. No changes made."
            return $false
        }
    } else {
        Write-Host "Service '$serviceName' does not exist."
        $install = Read-Host "Do you want to install the service? (y/n)"
        if ($install -like "y") {
            if (Test-Path $ListenerExePath) {
                Write-Host "Registering '$ListenerExePath' as a service with name '$serviceName'..."
                New-Service -Name $serviceName `
                            -BinaryPathName "`"$ListenerExePath`"" `
                            -DisplayName "Azure Relay Listener Service" `
                            -Description "Azure Relay service." `
                            -StartupType Automatic
                Start-Service -Name $serviceName
                Write-Host "Service '$serviceName' has been registered and started successfully."
                return $true
            } else {
                Write-Host "Error: listener.exe not found in the installation directory."
                exit 1
            }
        } else {
            $runListener = Read-Host "Do you want to run listener.exe directly? (y/n)"
            if ($runListener -like "y") {
                if (Test-Path $ListenerExePath) {
                    Write-Host "Starting listener.exe..."
                    Start-Process -FilePath $ListenerExePath -NoNewWindow
                } else {
                    Write-Host "Error: listener.exe not found in the installation directory."
                    exit 1
                }
            } else {
                Write-Host "Exiting script without making changes."
                exit 0
            }
        }
    }
}

# Main logic
Write-Host "Checking registry values..."
$registryUpdated = Manage-RegistryValues

Write-Host "Checking service..."
$serviceUpdated = Manage-Service -ListenerExePath $listenerExePath

if (-not $registryUpdated -and -not $serviceUpdated) {
    Write-Host "No changes were made to registry values or the service. Exiting script."
    exit 0
}

Write-Host "Script execution completed."
Read-Host "Press Enter to exit"
