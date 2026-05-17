$ErrorActionPreference = "Stop"

function Log($m){ Write-Output "$(Get-Date -Format o) $m" }

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
    Log "Starting Hosted Agent RBAC fix"

    $roleId = "53ca6127-db72-4b80-b1b0-d745d6d5456d"

    $ai = Retry {
        Get-AzCognitiveServicesAccount | Select-Object -First 1
    } "Resolve Foundry"

    $agents = Retry {
        Get-AzADServicePrincipal -DisplayNameStartsWith "Agent"
    } "Resolve agent identities"

    foreach ($a in $agents) {
        New-AzRoleAssignment `
            -RoleDefinitionId $roleId `
            -ObjectId $a.Id `
            -Scope $ai.Id `
            -ErrorAction SilentlyContinue | Out-Null

        Log "Assigned role to $($a.DisplayName)"
    }

    Log "Hosted Agent RBAC fix complete"
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    throw
}
