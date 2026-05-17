$ErrorActionPreference = "Stop"

function Log($m){ Write-Output "$(Get-Date -Format o) $m" }

function Connect-LabAzAccount {
    $clientId     = "@lab.CloudSubscription.AppId"
    $clientSecret = "@lab.CloudSubscription.AppSecret"
    $tenantId     = "@lab.CloudSubscription.TenantId"
    $subscription = "@lab.CloudSubscription.Id"

    Log "Logging into Az PowerShell"

    $secureSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($clientId, $secureSecret)

    Connect-AzAccount `
        -ServicePrincipal `
        -Credential $credential `
        -Tenant $tenantId `
        -Subscription $subscription | Out-Null

    Set-AzContext -Subscription $subscription -Tenant $tenantId | Out-Null

    Log "Az PowerShell context set to $subscription"
}

function Retry($script, $desc){
    for($i = 1; $i -le 20; $i++){
        try {
            Log ("Attempt {0}: {1}" -f $i, $desc)
            return & $script
        }
        catch {
            if($i -eq 20){ throw }
            Start-Sleep 15
        }
    }
}

try {
    Log "Starting RBAC configuration"

    Connect-LabAzAccount

    $userUpn = "@lab.CloudPortalCredential(User1).Username"

    $foundryUserRoleId           = "53ca6127-db72-4b80-b1b0-d745d6d5456d"
    $foundryProjectManagerRoleId = "eadc314b-1a2d-4efa-be10-5d325db5065e"

    $user = Get-AzADUser -UserPrincipalName $userUpn
    if (-not $user) { throw "User not found" }

    $ai = Retry {
        Get-AzCognitiveServicesAccount | Select-Object -First 1
    } "Resolve Foundry account"

    $project = Retry {
        Get-AzResource -ResourceType "Microsoft.CognitiveServices/accounts/projects" -ExpandProperties |
        Where-Object { $_.Identity.PrincipalId } |
        Select-Object -First 1
    } "Resolve project identity"

    $assignments = @(
        @{Role=$foundryUserRoleId; Obj=$user.Id; Desc="User Foundry User"},
        @{Role=$foundryUserRoleId; Obj=$project.Identity.PrincipalId; Desc="MI Foundry User"},
        @{Role=$foundryProjectManagerRoleId; Obj=$user.Id; Desc="User Project Manager"}
    )

    foreach ($a in $assignments) {
        New-AzRoleAssignment `
            -RoleDefinitionId $a.Role `
            -ObjectId $a.Obj `
            -Scope $ai.Id `
            -ErrorAction SilentlyContinue | Out-Null

        Log "Assigned: $($a.Desc)"
    }

    Log "RBAC configuration complete"
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    throw
}
