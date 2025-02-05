# Define registry key, service name, and default installation directory
$regKey = "HKLM:\SOFTWARE\iam_automation"
$serviceName = "AzureRelayListener"
$defaultInstallDir = "C:\program files\iam_agent"

# Define NSSM installation folder and path to NSSM executable
$NssmInstallFolder = "C:\nssm"
$nssmPath = Join-Path $NssmInstallFolder "win64\nssm.exe"

# Function: Install-NSSM if not already present
function Install-NSSM {
    param (
        [string]$InstallFolder = "C:\nssm"
    )
    $nssmZipUrl = "https://nssm.cc/release/nssm-2.24.zip"
    $zipFile = Join-Path $env:TEMP "nssm.zip"
    $tempExtract = Join-Path $env:TEMP "nssm_extract"

    Write-Host "NSSM not found. Downloading NSSM from $nssmZipUrl..."
    try {
        Invoke-WebRequest -Uri $nssmZipUrl -OutFile $zipFile -UseBasicParsing
    } catch {
        Write-Host "Error downloading NSSM: $_"
        exit 1
    }

    Write-Host "Extracting NSSM..."
    try {
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
        Expand-Archive -Path $zipFile -DestinationPath $tempExtract -Force
    } catch {
        Write-Host "Error extracting NSSM: $_"
        exit 1
    }
    
    # Locate the extracted NSSM folder (e.g. "nssm-2.24")
    $extractedFolder = Get-ChildItem -Path $tempExtract | Where-Object { $_.PSIsContainer } | Select-Object -First 1
    if (-not $extractedFolder) {
        Write-Host "Failed to locate extracted NSSM folder."
        exit 1
    }
    $sourceWin64 = Join-Path $extractedFolder.FullName "win64"
    $destWin64 = Join-Path $InstallFolder "win64"
    if (-not (Test-Path $destWin64)) {
        New-Item -ItemType Directory -Path $destWin64 -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $sourceWin64 "*") -Destination $destWin64 -Recurse -Force

    Remove-Item $zipFile -Force
    Remove-Item $tempExtract -Recurse -Force
    Write-Host "NSSM installed successfully to $InstallFolder."
}

# Check if NSSM is installed, if not then install it
if (-not (Test-Path $nssmPath)) {
    Install-NSSM -InstallFolder $NssmInstallFolder
}

# Function: Download a file from a URL
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

# Prompt for installation directory (default provided)
$installDir = Read-Host "Enter installation directory for listener.exe (Default: $defaultInstallDir)"
if ([string]::IsNullOrWhiteSpace($installDir)) {
    $installDir = $defaultInstallDir
}

if (-not (Test-Path $installDir)) {
    Write-Host "Creating installation directory: $installDir"
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# Define the GitHub URL for listener.exe (your provided URL)
$listenerUrl = "https://raw.githubusercontent.com/nigelwebsterMGN/iam_agent/main/listener_1.0.0.exe"
$listenerExePath = Join-Path $installDir "listener_1.0.0.exe"

# Download listener.exe to the chosen installation directory
Download-File -Url $listenerUrl -Destination $listenerExePath

# Function: Manage registry values
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

# Function: Manage the service registration using NSSM
function Manage-Service {
    param(
         [string]$ListenerExePath
    )
    
    # Check if the service already exists
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Write-Host "Service '$serviceName' already exists."
        $uninstall = Read-Host "Do you want to uninstall the service? (y/n)"
        if ($uninstall -like "y") {
            Write-Host "Stopping and removing service '$serviceName'..."
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            & $nssmPath remove $serviceName confirm
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
            Write-Host "Registering '$ListenerExePath' as a service using NSSM..."
            & $nssmPath install $serviceName $ListenerExePath
            # Set the working directory for the service
            & $nssmPath set $serviceName AppDirectory $installDir
            # Optionally redirect standard output and error to log files
            & $nssmPath set $serviceName AppStdout (Join-Path $installDir "listener_stdout.log")
            & $nssmPath set $serviceName AppStderr (Join-Path $installDir "listener_stderr.log")
            
            Write-Host "Starting service '$serviceName'..."
            Start-Service -Name $serviceName
            Write-Host "Service '$serviceName' has been registered and started successfully."
            return $true
        } else {
            $runListener = Read-Host "Do you want to run listener.exe directly as an application? (y/n)"
            if ($runListener -like "y") {
                if (Test-Path $ListenerExePath) {
                    Write-Host "Starting listener.exe directly..."
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

Write-Host "Managing service registration..."
$serviceUpdated = Manage-Service -ListenerExePath $listenerExePath

if (-not $registryUpdated -and -not $serviceUpdated) {
    Write-Host "No changes were made to registry values or the service. Exiting script."
    exit 0
}

Write-Host "Script execution completed."
Read-Host "Press Enter to exit"
