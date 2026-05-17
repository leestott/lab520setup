# Skillable Lab PowerShell Scripts

This repository contains four PowerShell scripts designed for a Skillable lab to:

1. Install the Azure Developer CLI (azd)
2. Deploy resources with azd
3. Apply RBAC role assignments for Microsoft Foundry
4. Fix hosted agent RBAC after deployment

It includes execution order, configuration details, logging behavior, and setup instructions.

## Files and Purpose

### 1. `azd_install.ps1`
- **Purpose**: Installs or upgrades the Azure Developer CLI (`azd`) on the Windows VM. Ensures that `azd` is available in the PATH and waits for the command to be usable.
- **Configuration**:
  - Blocking: **Yes**
  - Timeout: **15 minutes**
- **Logging**:
  - Desktop log file: `azd-install.log` (fallback to `%TEMP%` if Desktop is unavailable)
  - Uses `Start-Transcript` and a custom `Log` function to write timestamped output.
- **Setup Instructions**:
  1. Configure as a Blocking VM script in Skillable with a 15-minute timeout.
  2. The script begins a transcript to the Desktop log file.
  3. It downloads and runs the azd installer.
  4. It updates the PATH and loops to validate `azd version` is available.
  5. The script stops transcription at the end.

### 2. `azd_deployment.ps1`
- **Purpose**: Authenticates using Azure CLI with service principal credentials and runs `azd up` to deploy Bicep/ARM resources.
- **Configuration**:
  - Blocking: **Yes**
  - Timeout: **75 minutes**
- **Logging**:
  - Desktop log file: `azd-deployment.log` (fallback to `%TEMP%` if Desktop is unavailable)
  - Uses `Start-Transcript` and a custom `Log` function.
- **Features**:
  - Authenticates with Azure CLI (`az login`) so that `azd` receives proper credentials.
  - Authenticates `azd` directly with the same service principal to avoid interactive auth waits.
  - Ensures `azd` is available in PATH and retries `azd version` until successful.
  - Changes directory to `C:\Users\LabUser\Desktop\Build26-LAB520-main` before running `azd up` (fails early if folder is missing).
  - Executes `azd up --no-prompt`, writing output to log.
  - Does **not** include any RBAC assignments to avoid duplication and race conditions.
- **Setup Instructions**:
  1. Configure as a Blocking VM script with a 75-minute timeout.
  2. Ensure the AZ CLI and credentials environment are present.
  3. The script handles Azure CLI login and deployment.

### 3. `rbac_bootstrap.ps1`
- **Purpose**: (Cloud Platform) Applies RBAC role assignments to the lab user and project managed identity for Foundry resources.
- **Configuration**:
  - Blocking: **Yes** (recommended)
  - Timeout: **15 minutes**
- **Logging**:
  - Writes to standard output for lifecycle logs.
- **Features**:
  - Authenticates to Az PowerShell with `Connect-AzAccount` using the lab service principal.
  - Uses Az PowerShell cmdlets to retrieve the Foundry Cognitive Services account and project identity.
  - Retry loops are used for resolved resources with logging of attempts.
  - Applies role assignments:
    - Foundry User to the lab user
    - Foundry User to the project managed identity
    - Foundry Project Manager to the lab user
  - Idempotent approach with `-ErrorAction SilentlyContinue`.
- **Setup Instructions**:
  1. Configure as a Blocking Cloud Platform script with a 15-minute timeout.
  2. Ensure that `azd up` has completed and resources exist.
  3. The script resolves users and identities, then applies RBAC roles.

### 4. `hosted_agent_fix.ps1`
- **Purpose**: (VM) After deployment delay, assigns Foundry User RBAC to hosted agent identities (service principals) so hosted agents function correctly.
- **Configuration**:
  - Blocking: **No**
  - Delay: **420 seconds (7 minutes)**
  - Timeout: **10 minutes**
- **Logging**:
  - Writes to standard output.
- **Features**:
  - Retry loop for resolving Foundry account and agent identities (`Get-AzADServicePrincipal -DisplayNameStartsWith "Agent"`).
  - Applies Foundry User role idempotently to each agent identity.
- **Setup Instructions**:
  1. Configure as a non-blocking VM script with a 10-minute timeout and ~420-second delay.
  2. After deployment, script runs and assigns RBAC roles to agent identities.

## Execution Order
1. **Resource Provider Registration** (system-owned)
2. **AZD Install Script (`azd_install.ps1`)** — Blocking
3. **AZD Deployment Script (`azd_deployment.ps1`)** — Blocking
4. **RBAC Bootstrap Script (`rbac_bootstrap.ps1`)** — Blocking
5. **Hosted Agent RBAC Fix Script (`hosted_agent_fix.ps1`)** — Delayed, non-blocking
6. **Teardown** (system-owned)

## Logging and Diagnostics
- VM scripts use `Start-Transcript` to Desktop (or `%TEMP%`) log files.
- Standard output includes timestamped messages via the `Log` function.
- Cloud Platform RBAC script writes to standard output only.

## Timeout Settings Summary
| Script                      | Timeout    | Blocking | Delay    |
|----------------------------|------------|----------|----------|
| azd_install.ps1            | 15 minutes | Yes      | N/A      |
| azd_deployment.ps1         | 75 minutes | Yes      | N/A      |
| rbac_bootstrap.ps1         | 15 minutes | Yes      | N/A      |
| hosted_agent_fix.ps1       | 10 minutes | No       | 420 sec  |

## Best Practices
- Ensure AZD Install script is blocking so that `azd` CLI is available for deployment.
- Do not duplicate RBAC logic in the deployment script; use the Cloud Platform script exclusively.
- Use Desktop logging for VM scripts to surface logs to learners.
- Wrap variable references properly to avoid PowerShell parsing issues (e.g., using format strings like `("Attempt {0}: {1}" -f $i, $name)`).
- Adjust timeouts conservatively based on deployment region performance.

## Support
If issues occur, review Desktop logs for VM scripts and standard output for cloud logs. Verify service principal credentials, Azure context (connectivity), and that cognitive services resources are present.
