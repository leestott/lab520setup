$ErrorActionPreference = "Stop"

function Get-LogPath {
    param([string]$Name)
    $desktop = [Environment]::GetFolderPath("Desktop")
    if ($desktop -and (Test-Path $desktop)) { return Join-Path $desktop $Name }
    return Join-Path $env:TEMP $Name
}

$logPath = Get-LogPath "azd-deployment.log"
Start-Transcript -Path $logPath -Force | Out-Null

function Log($m){ Write-Host "$(Get-Date -Format o) $m" }

function Retry($script, $name){
    for($i = 1; $i -le 10; $i++){
        try {
            Log ("Attempt {0}: {1}" -f $i, $name)
            return & $script
        }
        catch {
            if($i -eq 10){ throw }
            Start-Sleep 15
        }
    }
}

try {
    Log "Starting AZD deployment"

    # ✅ CRITICAL FIX: disable update check
    $env:AZD_DISABLE_UPDATE_CHECK = "true"

    $clientId     = "@lab.CloudSubscription.AppId"
    $clientSecret = "@lab.CloudSubscription.AppSecret"
    $tenantId     = "@lab.CloudSubscription.TenantId"

    az login --service-principal `
        --username $clientId `
        --password $clientSecret `
        --tenant $tenantId | Out-Null

    $env:PATH += ";C:\utils\azd\bin"

    # ✅ Wrapped in cmd to avoid PowerShell killing on warnings
    Retry { cmd /c azd version > $null 2>&1 } "Wait for AZD"

    Log "Running azd up"
    cmd /c azd up --no-prompt 2>&1 | ForEach-Object { Write-Host $_ }

    Log "AZD deployment completed"
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}