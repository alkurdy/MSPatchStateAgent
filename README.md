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

## Usage & Parameters

The agent can be executed manually or as a scheduled task:

```powershell
& .\src\PatchStateAgent.ps1 [-SimulateSmbFailure] [-SimulateSmtpFailure] [-BypassOrchestratorCheck]
```

### Core Parameters
- `-SimulateSmbFailure`: Forces the SMB upload to fail to verify the SMTP fallback transmission path.
- `-SimulateSmtpFailure`: Forces the SMTP delivery to fail to verify local cache fallback writing.
- `-BypassOrchestratorCheck`: Forces execution of the agent even if the cooperative registry semaphore (`OrchestratorTriggered = 1`) is active. This should be used by external orchestrators (like Windmill or Ansible) to ensure direct runs always execute to completion.

For full architectural details, registry configuration keys, and transport fallback strategies, see [SPEC.md](SPEC.md).
