# PatchStateAgent (PSA)

`PatchStateAgent` is a robust, lightweight PowerShell-based AI agent designed to capture Windows server patch states like Git commits, compute diffs, and export structured JSON data to a centralized location.

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

## Setup & Testing Quickstart

See [SPEC.md](SPEC.md) for full architecture, parameters, registry configuration keys, and transport fallback strategies.
