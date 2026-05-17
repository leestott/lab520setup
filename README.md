# Skillable Lab PowerShell Scripts

This repository contains two PowerShell scripts used in the Skillable lab (LAB520) lifecycle:

1. Install the Azure Developer CLI (azd)
2. Deploy resources, assign RBAC roles, and configure hosted agent identities — all in one combined script

> **Note**: `azd_deployment.ps1`, `rbac_bootstrap.ps1`, and `hosted_agent_fix.ps1` are superseded by `deploy.ps1` and are retained for reference only.

It includes execution order, configuration details, logging behavior, and setup instructions.

## Files and Purpose

### 1. `azd_install.ps1`
- **Purpose**: Installs or upgrades the Azure Developer CLI (`azd`) to `C:\utils\azd` on the Windows VM. Ensures that `azd` is available and waits for the command to be usable.
- **Configuration**:
  - Blocking: **Yes**
  - Timeout: **15 minutes**
- **Logging**:
  - Desktop log file: `azd-install.log` (fallback to `%TEMP%` if Desktop is unavailable)
  - Uses `Start-Transcript` and a custom `Log` function to write timestamped output.
- **Setup Instructions**:
  1. Configure as a Blocking VM script in Skillable with a 15-minute timeout.
  2. The script begins a transcript to the Desktop log file.
  3. It downloads and runs the azd installer to `C:\utils\azd`.
  4. It updates the PATH and loops to validate `azd version` is available.
  5. The script stops transcription at the end.

### 2. `deploy.ps1` *(replaces `azd_deployment.ps1`, `rbac_bootstrap.ps1`, and `hosted_agent_fix.ps1`)*
- **Purpose**: All-in-one lifecycle script. Authenticates, runs `azd up`, then applies all required RBAC role assignments for the lab user, project managed identity, deployment service principal, and hosted agent identities.
- **Configuration**:
  - Blocking: **Yes**
  - Timeout: **90 minutes**
- **Logging**:
  - Desktop log file: `lifecycle-165767.log`
  - Uses `Start-Transcript`.
- **Features**:
  - Authenticates to Az PowerShell (`Connect-AzAccount`) using the lab service principal.
  - Resolves the lab user object ID with a retry loop (10 attempts, 15 s gap).
  - Resolves the deployment service principal object ID (`Get-AzADServicePrincipal`).
  - Adds `C:\utils\azd\bin` to `$env:PATH` at runtime (required because `azd_install.ps1` modifies the machine PATH, which isn't inherited by a new session).
  - Changes directory to `C:\Users\LabUser\Desktop\Build26-LAB520-main`; fails early if the folder is missing.
  - Runs `azd auth login`, `azd env new`, sets `AZURE_PRINCIPAL_ID`, `AZURE_PRINCIPAL_TYPE`, `AZURE_TENANT_ID`, then `azd up --no-prompt`.
  - After deployment, uses `Invoke-WithRetry` (up to 12 attempts, 15 s gap) to wait for the Foundry Cognitive Services account and project managed identity to be available in ARM.
  - Applies Foundry RBAC roles idempotently (`Grant-Role` helper skips `RoleAssignmentExists`):
    - **Foundry User** to the deployment service principal
    - **Foundry User** to the lab user
    - **Foundry Project Manager** to the lab user
    - **Foundry User** to the project managed identity
  - Polls up to 5 minutes for agent service identities (`*-AgentIdentity`) and grants each **Foundry User**.
  - Waits **120 seconds** for RBAC propagation before completing.
- **Setup Instructions**:
  1. Ensure `azd_install.ps1` has completed first (installs azd to `C:\utils\azd`).
  2. Configure as a Blocking VM script with a 90-minute timeout.
  3. The lab project folder `C:\Users\LabUser\Desktop\Build26-LAB520-main` must contain `azure.yaml`.

## Execution Order
1. **Resource Provider Registration** (system-owned)
2. **AZD Install Script (`azd_install.ps1`)** — Blocking, 15 min
3. **Deploy Script (`deploy.ps1`)** — Blocking, 90 min
4. **Teardown** (system-owned)

## Logging and Diagnostics
- Both scripts use `Start-Transcript` to Desktop log files.
- `deploy.ps1` logs to `C:\Users\LabUser\Desktop\lifecycle-165767.log`.
- `azd_install.ps1` logs to `C:\Users\LabUser\Desktop\azd-install.log`.
- All retry attempts and RBAC grant outcomes are written to the transcript.

## Timeout Settings Summary
| Script             | Timeout    | Blocking | Notes                              |
|--------------------|------------|----------|------------------------------------|
| azd_install.ps1   | 15 minutes | Yes      | Must complete before deploy.ps1    |
| deploy.ps1        | 90 minutes | Yes      | Includes azd up + all RBAC setup   |

## Best Practices
- `azd_install.ps1` must be blocking so `azd` is present before `deploy.ps1` runs.
- `deploy.ps1` adds `C:\utils\azd\bin` to `$env:PATH` at runtime — do not rely on the machine PATH being inherited.
- Wrap PowerShell variable references that are followed by `:` or other delimiter characters in `${}` (e.g. `${maxAttempts}`) to avoid scope-qualifier parse errors.
- Adjust the 90-minute timeout upward for slower Azure regions if `azd up` consistently times out.

## Support
If issues occur, review `C:\Users\LabUser\Desktop\lifecycle-165767.log`. The log includes every retry attempt, RBAC grant result, and the full stack trace of any fatal error. Verify service principal credentials, that the lab project folder exists, and that Cognitive Services resources are present in the resource group.
