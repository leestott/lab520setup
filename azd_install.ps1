$ErrorActionPreference = "Stop"

function Get-LogPath {
    param([string]$Name)
    $desktop = [Environment]::GetFolderPath("Desktop")
    if ($desktop -and (Test-Path $desktop)) { return Join-Path $desktop $Name }
    return Join-Path $env:TEMP $Name
}

$logPath = Get-LogPath "azd-install.log"
Start-Transcript -Path $logPath -Force | Out-Null

function Log($m){ Write-Host "$(Get-Date -Format o) $m" }

function Download-AZD {
    param([string]$InstallerPath)

    for ($i = 1; $i -le 10; $i++) {
        try {
            Log ("Attempt {0}: Downloading AZD installer" -f $i)

            Invoke-RestMethod https://aka.ms/install-azd.ps1 `
                -OutFile $InstallerPath `
                -ErrorAction Stop

            return
        }
        catch {
            Log ("Attempt {0} failed: {1}" -f $i, $_.Exception.Message)
            Start-Sleep 10
        }
    }

    throw "Failed to download AZD installer after retries"
}

try {
    Log "Starting AZD installation"

    $script = Join-Path $env:TEMP "install-azd.ps1"
    Download-AZD -InstallerPath $script

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -InstallFolder "C:\utils\azd"

    if ($LASTEXITCODE -ne 0) {
        throw "AZD installer failed"
    }

    $env:PATH += ";C:\utils\azd\bin"

    # Wait for AZD to be usable (cmd wrapper avoids EAP issues)
    for ($i = 1; $i -le 10; $i++) {
        try {
            cmd /c azd version > $null 2>&1
            Log "AZD available"
            break
        }
        catch {
            if ($i -eq 10) { throw "AZD not available after install" }
            Start-Sleep 5
        }
    }

    Log "AZD installation complete"
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}