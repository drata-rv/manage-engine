# ManageEngine to Drata Sync

This PowerShell script extracts device compliance data from ManageEngine Endpoint Central **Cloud (SaaS, US region)** and pushes it to Drata's Custom Device Connection API. It normalizes system inventory, software presence, and configuration states into the fixed JSON format required by Drata.

## Mechanism of Action

The ManageEngine REST API (v1.4) does not expose all required compliance data directly. Therefore, this integration uses a hybrid data ingestion model:
1. **API Data:** Device identities, user bindings, OS patch statuses, antivirus software presence, and password managers are queried live via the ManageEngine Cloud API, authenticated with Zoho OAuth 2.0.
2. **CSV Data:** Hard drive encryption (BitLocker) and screen lock timeouts are parsed from locally scheduled CSV report exports.
3. **Payload Construction:** The script matches the live API data with offline CSV records per device, asserts compliance booleans, and POSTs the result to Drata.

## Prerequisites

- **Host:** Windows Server/EC2 instance.
- **Network:** Outbound HTTPS to `endpointcentral.manageengine.com`, `accounts.zoho.com`, and `app.drata.com`. No inbound rules required.
- **Zoho OAuth App:** A Server-based or Self Client OAuth application registered at `https://api-console.zoho.com`. The app must be authorized with the following scopes:
  - `DesktopCentralCloud.SOM.READ`
  - `DesktopCentralCloud.Inventory.READ`
  - `DesktopCentralCloud.PatchMgmt.READ`
- **Reporting Dependency:** Two ManageEngine reports must be scheduled to export automatically prior to the script's execution time:
  - `C:\DrataSync\reports\bitlocker_export.csv`
  - `C:\DrataSync\reports\screenlock_export.csv`

## Configuration

All credentials are injected via Windows System Environment Variables. Define the following on the host machine before running:

- `ME_CLIENT_ID`: OAuth Client ID from the Zoho Developer Console (`api-console.zoho.com`).
- `ME_CLIENT_SECRET`: OAuth Client Secret from the Zoho Developer Console.
- `ME_REFRESH_TOKEN`: Long-lived OAuth refresh token obtained during the one-time authorization grant. Does not expire unless unused for 6+ months or explicitly revoked. Store securely (e.g., AWS Secrets Manager, Windows DPAPI).
- `DRATA_API_TOKEN`: Bearer token generated within Drata for the Custom Device Connection.

### One-Time OAuth Setup

1. Register a **Self Client** application at `https://api-console.zoho.com`.
2. Request a grant code for the three scopes above (comma-separated, `access_type=offline`).
3. Exchange the grant code for tokens via:
   ```
   POST https://accounts.zoho.com/oauth/v2/token
     grant_type=authorization_code
     &code=<GRANT_CODE>
     &client_id=<CLIENT_ID>
     &client_secret=<CLIENT_SECRET>
     &redirect_uri=<REDIRECT_URI>
   ```
4. Store the returned `refresh_token` as the `ME_REFRESH_TOKEN` environment variable. The script handles access token renewal automatically on every run.

Heuristics such as approved Antivirus software names and the maximum Screen Lock idle timeout are defined as constants at the top of [ManageEngineToDrataSync.ps1](ManageEngineToDrataSync.ps1).

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
