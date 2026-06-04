# PatchStateAgent (PSA)

`PatchStateAgent` is a robust, lightweight PowerShell-based monitoring agent designed to capture Windows server patch states like Git commits, compute diffs, and export structured JSON data to a centralized location.

## Repository Directory Structure

```
MSPatchStateAgent/
├── SPEC.md                 # Technical Specification
├── README.md               # Project overview and installation summary
├── chocolatey/             # Chocolatey packaging resources
│   ├── patchstateagent.nuspec
│   └── tools/
│       ├── chocolateyInstall.ps1
│       └── chocolateyUninstall.ps1
├── src/                    # Source code
│   └── PatchStateAgent.ps1 # Core Agent Script (skeleton staging)
└── tests/                  # Verification and testing
    └── PatchStateAgent.Tests.ps1 # Pester Unit Tests skeleton
```

## Interactive Demo Examples

You can view simulated reporting output using the following local example files in this repository:
- **Interactive Dashboard:** [demo-dashboard.html](demo-dashboard.html) (a pre-generated HTML report with rich aesthetics and interactive limits)
- **Structured JSON Report:** [demo-report.json](demo-report.json) (the raw historical payload with state metrics)

## Script Usage & Parameters

The agent can be executed manually or scheduled using standard PowerShell 5.1+:

```powershell
& .\src\PatchStateAgent.ps1 [-SimulateSmbFailure] [-SimulateSmtpFailure] [-BypassOrchestratorCheck] [-HistoryLimit <int>] [-MaxDisplayChanges <int>]
```

### Core Script Parameters
- `-SimulateSmbFailure`: Forces the SMB upload to fail to verify the SMTP fallback transmission path.
- `-SimulateSmtpFailure`: Forces the SMTP delivery to fail to verify local cache fallback writing.
- `-BypassOrchestratorCheck`: Bypasses the registry semaphore (`OrchestratorTriggered = 1`) check. Used by external orchestrators (like Windmill or Ansible) to ensure direct runs always execute to completion.
- `-HistoryLimit <int>`: Limits the maximum number of historical runs retained in the history JSON/HTML logs. Defaults to `30`.
- `-MaxDisplayChanges <int>`: Configures the default number of change entries to show initially on the HTML dashboard. Defaults to `50`.

---

## Chocolatey Deployment

You can package and deploy `PatchStateAgent` as a standard Windows service/scheduled task using Chocolatey:

```powershell
choco install patchstateagent --source=".\chocolatey" --params="/ServerTag:SQL /SmbPath:\\fileserver\reports /SmtpServer:smtp.corp.local /SmtpTo:ops@corp.local"
```

### Supported Chocolatey Parameters

The Chocolatey installer provisions the scheduled task and writes configuration parameters directly to `HKLM:\SOFTWARE\PatchStateAgent\Config\`:

* `/ServerTag:<string>` - Classification tag for the machine (e.g., SQL, Web, DMZ. Default: `Untagged`).
* `/SmbPath:<string>` - Target UNC folder path for JSON and HTML report uploads (e.g., `\\unc\share\reports`).
* `/SmtpServer:<string>` - Fallback SMTP server address (e.g., `smtp.corp.local`).
* `/SmtpTo:<string>` - Recipient email address for patch status notifications.
* `/SmtpFrom:<string>` - Sender email address (Default: `psa@<computer_name>.local`).
* `/SmtpPort:<int>` - Port for SMTP server communication (Default: `25`).
* `/HistoryLimit:<int>` - Maximum historical runs to keep in history logs (Default: `30`).
* `/MaxDisplayChanges:<int>` - Default number of change entries to display in the dashboard table (Default: `50`).

For full architectural details, registry configuration keys, and transport fallback strategies, see [SPEC.md](SPEC.md).
