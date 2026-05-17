$logPath = "C:\Users\LabUser\Desktop\lifecycle-165767.log"
Start-Transcript -Path $logPath -Force

try {
    # === Variables ===
    $appId     = "@lab.CloudSubscription.AppId"
    $appSecret = "@lab.CloudSubscription.AppSecret"
    $tenantId  = "@lab.CloudSubscription.TenantId"
    $subId     = "@lab.CloudSubscription.Id"
    $region    = "@lab.CloudResourceGroup(ResourceGroup1).Location"
    $envName   = "build@lab.LabInstance.Id"
    $rg        = "@lab.CloudResourceGroup(ResourceGroup1).Name"
    $userUpn   = "@lab.CloudPortalCredential(User1).Username"

    $ErrorActionPreference = "Stop"

    # Run an external command, capture stderr to a file so the Python traceback
    # survives, and only throw after we've logged the full error.
    function Invoke-External($label, [ScriptBlock]$cmd) {
        Write-Host ">>> $label"
        $stderrFile = Join-Path $env:TEMP "extcmd-stderr.txt"
        if (Test-Path $stderrFile) { Remove-Item $stderrFile -Force }

        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $cmd 2> $stderrFile | ForEach-Object { Write-Host $_ }
        } finally {
            $ErrorActionPreference = $prev
        }

        if (Test-Path $stderrFile) {
            $err = Get-Content $stderrFile -Raw
            if ($err) { Write-Host "STDERR: $err" }
        }
        if ($LASTEXITCODE -ne 0) { throw "$label failed (exit $LASTEXITCODE)." }
    }

    function Grant-Role($principalId, $roleId, $scope, $label) {
        try {
            New-AzRoleAssignment -RoleDefinitionId $roleId -ObjectId $principalId -Scope $scope -ErrorAction Stop | Out-Null
            Write-Host "Granted $label to $principalId"
        } catch {
            if ($_.Exception.Message -match "already exists|RoleAssignmentExists") {
                Write-Host "Skip (already exists): $label for $principalId"
            } else { throw }
        }
    }

    # Retry a scriptblock until it returns a non-null/non-empty result or throws after $maxAttempts
    function Invoke-WithRetry([ScriptBlock]$sb, [string]$label, [int]$maxAttempts = 12, [int]$delaySec = 15) {
        for ($i = 1; $i -le $maxAttempts; $i++) {
            try {
                $result = & $sb
                if ($result) { return $result }
                Write-Host "  $label attempt $i/${maxAttempts}: empty result, retrying in ${delaySec}s..."
            } catch {
                Write-Host "  $label attempt $i/${maxAttempts}: $($_.Exception.Message)"
                if ($i -eq $maxAttempts) { throw }
            }
            Start-Sleep -Seconds $delaySec
        }
        throw "$label did not return a result after $maxAttempts attempts."
    }

    # === Az PowerShell login (only auth we need) ===
    Write-Host ">>> Connect-AzAccount"
    $securePwd = ConvertTo-SecureString $appSecret -AsPlainText -Force
    $psCred    = New-Object System.Management.Automation.PSCredential ($appId, $securePwd)
    Connect-AzAccount -ServicePrincipal -Tenant $tenantId -Credential $psCred -Subscription $subId | Out-Null

    # === Resolve lab user object ID (with retry) ===
    Write-Host ">>> Resolve user $userUpn"
    $userId  = $null
    $retries = 0
    while (-not $userId -and $retries -lt 10) {
        try { $userId = (Get-AzADUser -UserPrincipalName $userUpn -ErrorAction Stop).Id }
        catch { Write-Host "  attempt $($retries+1): $($_.Exception.Message)" }
        if (-not $userId) { Start-Sleep -Seconds 15; $retries++ }
    }
    if (-not $userId) { throw "Could not resolve user '$userUpn'." }
    Write-Host "userId = $userId"

    # === Resolve deployment SP object ID ===
    $spObjectId = (Get-AzADServicePrincipal -ApplicationId $appId -ErrorAction Stop).Id
    Write-Host "spObjectId = $spObjectId"

    # === azd up ===
    $env:PATH += ";C:\utils\azd\bin"

    $labPath = "C:\Users\LabUser\Desktop\Build26-LAB520-main"
    if (-not (Test-Path $labPath)) { throw "Lab folder not found: $labPath" }
    Set-Location $labPath

    Invoke-External "azd auth login" {
        azd auth login --client-id $appId --client-secret $appSecret --tenant-id $tenantId
    }
    Invoke-External "azd env new" {
        azd env new $envName --location $region --subscription $subId
    }

    azd env set AZURE_PRINCIPAL_ID   $userId
    azd env set AZURE_PRINCIPAL_TYPE "User"
    azd env set AZURE_TENANT_ID      $tenantId

    # Run azd up, capturing combined stdout+stderr so we can detect the known
    # post-provision race condition (agent version 404) and continue despite it.
    Write-Host ">>> azd up"
    $azdOutput = & azd up -e $envName --no-prompt 2>&1
    $azdOutput | ForEach-Object { Write-Host $_ }

    if ($LASTEXITCODE -ne 0) {
        $outputStr = ($azdOutput | Out-String)
        if ($outputStr -match 'event-postprovision|event-postdeploy' -and $outputStr -match 'not_found|404') {
            Write-Host "WARNING: azd up exited $LASTEXITCODE due to known post-provision race condition (agent version 404). All Azure resources provisioned successfully - continuing with RBAC setup."
        } else {
            throw "azd up failed (exit $LASTEXITCODE)."
        }
    }

    Write-Host ">>> azd up complete"

    # === Post-deploy role assignments ===
    $foundryUserRoleId           = "53ca6127-db72-4b80-b1b0-d745d6d5456d"  # Foundry User
    $foundryProjectManagerRoleId = "eadc314b-1a2d-4efa-be10-5d325db5065e"  # Foundry Project Manager

    $aiResource = Invoke-WithRetry {
        Get-AzCognitiveServicesAccount -ResourceGroupName $rg -ErrorAction Stop | Select-Object -First 1
    } "Get Foundry account"
    if (-not $aiResource) { throw "No Foundry account found in RG '$rg'." }
    $aiResourceId = $aiResource.Id
    $accountName  = $aiResource.AccountName
    Write-Host "aiResourceId = $aiResourceId"

    $aiProject = Invoke-WithRetry {
        $proj = Get-AzResource `
            -ResourceType "Microsoft.CognitiveServices/accounts/projects" `
            -ResourceGroupName $rg `
            -ExpandProperties -ErrorAction Stop | Select-Object -First 1
        if ($proj -and $proj.Identity.PrincipalId) { return $proj }
        return $null  # triggers retry
    } "Get project managed identity"
    $projectIdentityPrincipalId = $aiProject.Identity.PrincipalId

    Grant-Role $spObjectId               $foundryUserRoleId           $aiResourceId "Foundry User (deployment SP)"
    Grant-Role $userId                   $foundryUserRoleId           $aiResourceId "Foundry User (user)"
    Grant-Role $userId                   $foundryProjectManagerRoleId $aiResourceId "Foundry Project Manager (user)"
    Grant-Role $projectIdentityPrincipalId $foundryUserRoleId         $aiResourceId "Foundry User (project MI)"

    $deadline = (Get-Date).AddMinutes(5)
    $agentSps = @()
    do {
        $agentSps = Get-AzADServicePrincipal -SearchString $accountName |
            Where-Object {
                $_.ServicePrincipalType -eq "ServiceIdentity" -and
                $_.DisplayName -like "*-AgentIdentity"
            }
        if ($agentSps.Count -gt 0) { break }
        Write-Host "Waiting for agent identities..."
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)

    if ($agentSps.Count -eq 0) {
        Write-Host "WARNING: no agent identities found for '$accountName' after 5 minutes."
    } else {
        foreach ($sp in $agentSps) {
            Grant-Role $sp.Id $foundryUserRoleId $aiResourceId "Foundry User ($($sp.DisplayName))"
        }
    }

    # Allow Azure RBAC assignments time to propagate before any agent data-plane calls
    Write-Host ">>> Waiting 120 s for RBAC propagation..."
    Start-Sleep -Seconds 120

    Write-Host ">>> Lifecycle action complete."
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    throw
}
finally {
    Stop-Transcript
}