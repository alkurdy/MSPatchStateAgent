# Technical Specification: PatchStateAgent (PSA)

`PatchStateAgent` is a robust, lightweight PowerShell-based monitoring agent designed to capture Windows server patch states like Git commits, compute diffs, and export structured JSON data to a centralized location.

## 1. Core Philosophy (KISS)

* **Zero External Dependencies:** Runs natively on standard PowerShell 5.1+. No external binaries or heavy modules required.
* **Fail-Safe Architecture:** If the preferred transport layer (SMB) fails, it falls back sequentially to ensure no data loss.
* **Deterministic State:** Uses flat JSON files to mimic a Git repository's structural state instead of a complex database.

---

## 2. System Architecture & Workflows

### Execution Flow & Storage Fallbacks

The agent checks for an execution lock file or registry key (to honor Windmill orchestration overrides), processes the patch state, and executes a cascading fallback mechanism for data delivery.

```
[Start]
   │
   ▼
[Check Orchestrator Override?] ──(Yes)──► [Reset Flag & Exit]
   │ (No)
   ▼
[Capture Patch State & Compute Diff]
   │
   ▼
[Attempt SMB Upload] ──(Success)──► [Log & End]
   │ (Fail)
   ▼
[Attempt SMTP Email] ──(Success)──► [Log & End]
   │ (Fail)
   ▼
[Write to Local Cache Directory] ──► [Log Warning & End]
```

---

## 3. Component Specifications

### 3.1 State Capture & "Git" Diffing Engine

* **Commit Generation:** Captures `Get-HotFix` property arrays, strips noisy fields, and serializes them to a localized `current_state.json`.
* **Diff Generation:** Performs a reference comparison against `previous_state.json`.
* **Structured Output:** Generates a unified JSON payload (`patch_report.json`) designed for consumption by downstream AI models, APIs, or static HTML generators.

```json
{
  "timestamp": "2026-06-04T15:30:00Z",
  "computer_name": "PROD-SQL-01",
  "tag": "Database",
  "orchestrator_override": false,
  "summary": { "added": 2, "removed": 0 },
  "diff": [
    { "kb_id": "KB5034123", "action": "added", "installed_on": "2026-06-04" },
    { "kb_id": "KB5034441", "action": "added", "installed_on": "2026-06-04" }
  ]
}
```

### 3.2 Orchestrator Semaphores (Boolean Flag)

To prevent local Windows Scheduled Tasks from overlapping with active Windmill orchestration windows:

* The agent reads `HKLM:\SOFTWARE\PatchStateAgent\OrchestratorTriggered` (REG_DWORD / Boolean).
* If `True` ($1$), the agent skips execution, resets the flag to `False` ($0$), and logs the event.
* **Bypass Option:** The script supports a `-BypassOrchestratorCheck` switch parameter. When passed (e.g. during an orchestrator-led execution), the agent bypasses the `OrchestratorTriggered` check entirely, executing the run normally without skipping.

### 3.3 Cascading Transport Layer (Fail-Safe Strategy)

The agent will attempt delivery using a strict sequence:

| Priority | Method | Target / Failover Action |
| --- | --- | --- |
| **1 (Default)** | **SMB File Share** | Attempt to write JSON to `\\UNC\Share\reports\<tag>\<hostname>\` |
| **2 (Fallback)** | **SMTP Mail** | Send the JSON payload as an email body/attachment to a designated ingestion mailbox. |
| **3 (Last Resort)** | **Local Storage** | Cache the file locally to `C:\ProgramData\PatchStateAgent\undelivered\` for later collection. |

---

## 4. Logging & Robustness Standards

To ensure transparency for both human operators and monitoring tools, the agent adheres to a strict logging paradigm:

* **Log Location:** Event Viewer (`Application` log under source `PatchStateAgent`) and a local rotating text log file (`C:\ProgramData\PatchStateAgent\Logs\agent.log`).
* **Formatting:** Every entry must follow a standardized format: `[YYYY-MM-DD HH:mm:ss] [LEVEL] Message`.
* **Levels:**
  * `[INFO]`: Script started, flag checks, successful transmissions.
  * `[WARN]`: SMB failed, falling back to SMTP. Orchestrator flag bypassed run.
  * `[ERROR]`: Complete transport exhaustion (saved locally). Access denied to registry or system APIs.

---

## 5. Chocolatey Package Design (`.nuspec`)

The project will deploy cleanly via Chocolatey using package parameters for easy provisioning via Windmill.

### Package Parameters Supported

* `/ServerTag: <string>` (Categorizes the server e.g., Web, DMZ, SQL)
* `/SmbPath: <string>` (Target UNC path)
* `/SmtpServer: <string>` (Fallback SMTP relay server)

### Install Script Routine (`chocolateyInstall.ps1`)

1. Create `C:\ProgramData\PatchStateAgent\` directory hierarchy.
2. Drop the agent PowerShell core module and wrapper script.
3. Write configuration parameters directly to `HKLM:\SOFTWARE\PatchStateAgent\Config\`.
4. Register a local Windows Scheduled Task running under `NT AUTHORITY\SYSTEM` to fire daily.

---

## 6. Verification & Test Plan

* **Unit Tests:** Pester tests verifying that the diff engine accurately identifies added/removed/unchanged KB numbers.
* **Mock Failures:** A script argument `-SimulateSmbFailure` to force-test SMTP fallback routines.
* **Idempotency Check:** Confirming that installing the Chocolatey package multiple times on the same host does not duplicate Scheduled Tasks or wipe existing historical JSON "commits".
