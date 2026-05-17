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

function ConvertTo-ProcessArgument {
    param([string]$Argument)

    if ($Argument -notmatch '[\s"]') { return $Argument }

    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$ArgumentList,
        [Parameter(Mandatory=$true)][string]$Name,
        [int]$TimeoutSeconds = 4200
    )

    Log "Starting $Name"

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.Arguments = ($ArgumentList | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.UseShellExecute = $false

    [void]$process.Start()

    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { }
        throw "$Name timed out after $TimeoutSeconds seconds"
    }

    $stdout.Result | ForEach-Object { if ($_ -ne "") { Write-Host $_ } }
    $stderr.Result | ForEach-Object { if ($_ -ne "") { Write-Host $_ } }

    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)"
    }
}

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

    $env:AZD_DISABLE_UPDATE_CHECK = "true"

    $clientId     = "@lab.CloudSubscription.AppId"
    $clientSecret = "@lab.CloudSubscription.AppSecret"
    $tenantId     = "@lab.CloudSubscription.TenantId"
    $subscription = "@lab.CloudSubscription.Id"

    # AZ CLI login
    Log "Logging into Azure CLI"

    $loginResult = az login --service-principal `
        --username $clientId `
        --password $clientSecret `
        --tenant $tenantId 2>&1

    $loginResult | ForEach-Object { Write-Host $_ }

    # Validate login
    az account show 2>&1 | ForEach-Object { Write-Host $_ }

    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI login failed"
    }

    Log "Azure CLI login successful"

    # Set subscription
    az account set --subscription $subscription

    Log "Subscription set to $subscription"

    $env:PATH += ";C:\utils\azd\bin"
    $env:AZURE_CLIENT_ID = $clientId
    $env:AZURE_CLIENT_SECRET = $clientSecret
    $env:AZURE_TENANT_ID = $tenantId
    $env:AZURE_SUBSCRIPTION_ID = $subscription

    # Wait for AZD to be usable (wrapped via cmd)
    Retry { cmd /c azd version > $null 2>&1 } "Wait for AZD"

    Log "Logging into AZD"
    Invoke-LoggedCommand "azd" @("auth", "login", "--client-id", $clientId, "--client-secret", $clientSecret, "--tenant-id", $tenantId) "azd auth login" 300

    # === azd up ===
    $labPath = "C:\Users\LabUser\Desktop\Build26-LAB520-main"
    if (-not (Test-Path $labPath)) { throw "Lab folder not found: $labPath" }
    Set-Location $labPath

    # Run deployment
    Invoke-LoggedCommand "azd" @("up", "--no-prompt") "azd up" 4200

    Log "AZD deployment completed"
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
