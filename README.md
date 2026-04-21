# ManageEngine to Drata Sync

This PowerShell script extracts device compliance data from an on-premises ManageEngine Endpoint Central server and pushes it to Drata's Custom Device Connection API. It normalizes system inventory, software presence, and configuration states into the fixed JSON format required by Drata.

## Mechanism of Action

The ManageEngine REST API (v1.4) does not expose all required compliance data directly. Therefore, this integration uses a hybrid data ingestion model:
1. **API Data:** Device identities, user bindings, OS patch statuses, antivirus software presence, and password managers are queried live via the ManageEngine API.
2. **CSV Data:** Hard drive encryption (BitLocker) and screen lock timeouts are parsed from locally scheduled CSV report exports.
3. **Payload Construction:** The script matches the live API data with offline CSV records per device, asserts compliance booleans, and POSTs the result to Drata.

## Prerequisites

- **Host:** Windows Server/EC2 instance.
- **Network:** Outbound HTTPS access to Drata (`app.drata.com`) and line-of-sight to the ManageEngine server.
- **Reporting Dependency:** Two ManageEngine reports must be scheduled to export automatically prior to the script's execution time:
  - `C:\DrataSync\reports\bitlocker_export.csv`
  - `C:\DrataSync\reports\screenlock_export.csv`

## Configuration

Credentials and environment details are injected via System Environment Variables to maintain security. Define the following on the host machine before running:

- `ME_SERVER_URL`: Base URL of the ManageEngine instance (e.g., `http://10.0.0.15:8020`).
- `ME_AUTH_TOKEN`: Static token generated from the ManageEngine Admin integrations console.
- `DRATA_API_TOKEN`: Bearer token generated within Drata for the Custom Device Connection.

Heuristics, such as the approved Antivirus software names or maximum Screen Lock idle timeouts, are defined as constants at the top of the `ManageEngineToDrataSync.ps1` file.

## Execution

### Manual Verification
Open an Administrative PowerShell prompt and run:
```powershell
.\ManageEngineToDrataSync.ps1
```

### Scheduled Automation
Create a Windows Task Scheduler job to run daily.
- **Program:** `powershell.exe`
- **Arguments:** `-WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Path\To\ManageEngineToDrataSync.ps1"`

Ensure the schedule is configured to run after the BitLocker and Screen Lock CSV reports finish exporting from ManageEngine.

## Logging

Logs are automatically generated and appended to `C:\DrataSync\logs\SyncRun_YYYYMMDD.log`. Review this directory to identify omitted devices, unreachable endpoints, or HTTP rejection faults.
