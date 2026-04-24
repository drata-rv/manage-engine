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

## ManageEngine Report Configuration

BitLocker encryption status and screen lock policy are **not exposed by the ManageEngine REST API**. They must be sourced from the ManageEngine Reports module and delivered to the host machine as CSV files before each sync run.

### Scheduling the Reports in ME Cloud

Sign in to the Endpoint Central Cloud console at `https://endpointcentral.manageengine.com`.

**BitLocker Encryption Status**
1. Navigate to **Reports → Security Reports → BitLocker Encryption Status**.
2. Click **Schedule** and set the frequency to **Daily**, timed to complete at least **one hour before** the sync script runs (e.g., if the sync runs at 03:00, schedule the export for 02:00).
3. Set the export format to **CSV**.

**Screen Lock / Screensaver Policy**
1. Navigate to **Reports → Configuration Reports → Screen Lock** (or create a **Custom Report** scoped to the screensaver/lock policy if that report is not listed).
2. Apply the same daily schedule and CSV format as above.

### Delivering CSV Files to the Host

Because ME Cloud is SaaS, reports are generated server-side and cannot be written directly to the host filesystem. Choose one of the following delivery mechanisms:

- **Email delivery (most common):** Configure ME to email the CSV as an attachment to a mailbox accessible from the host. Use a scheduled PowerShell or Task Scheduler job to save the attachment to the expected directory. Libraries such as the `Send-MailMessage` equivalent flow or a mail-processing script can automate this.
- **Manual download:** Download the CSVs from the ME Cloud console and place them at the expected paths before each sync run. Only suitable for infrequent or manual runs.
- **Scripted API download:** If your ME Cloud license exposes a report download API endpoint, script the download step and prepend it to the sync schedule.

### Required CSV Column Headers

The script matches on exact column names. Validate these against a live export from your ME instance before deploying — header wording can vary between Endpoint Central versions.

**`bitlocker_export.csv`**

| Column | Expected Values |
|---|---|
| `Computer Name` | Device hostname (must match `resource_name` from the API) |
| `Protection Status` | `Protected` or `Unprotected` |

**`screenlock_export.csv`**

| Column | Expected Values |
|---|---|
| `Computer Name` | Device hostname |
| `Idle Timeout` | Integer in **seconds** (e.g., `600`) |

A device is considered screen-lock compliant when its `Idle Timeout` is greater than `0` and less than or equal to `900` seconds (15 minutes). This threshold is defined by `$MaxScreenLockTimeoutSeconds` at the top of the script.

> **Column name mismatch:** If a live export uses different headers (e.g., `ComputerName` instead of `Computer Name`), update the field references inside `Get-MEOfflineCSVData` in the script accordingly.

### Expected File Paths

By default the script reads:

```
C:\DrataSync\reports\bitlocker_export.csv
C:\DrataSync\reports\screenlock_export.csv
```

These can be overridden with the `-ReportDirectory` parameter:

```powershell
.\ManageEngineToDrataSync.ps1 -ReportDirectory "D:\CustomReports\"
```

---

## Configuration

All credentials are injected via Windows System Environment Variables. Define the following on the host machine before running:

- `ME_CLIENT_ID`: OAuth Client ID from the Zoho Developer Console (`api-console.zoho.com`).
- `ME_CLIENT_SECRET`: OAuth Client Secret from the Zoho Developer Console.
- `ME_REFRESH_TOKEN`: Long-lived OAuth refresh token obtained during the one-time authorization grant. Does not expire unless unused for 6+ months or explicitly revoked. Store securely (e.g., AWS Secrets Manager, Windows DPAPI).
- `DRATA_API_TOKEN`: Bearer token generated within Drata for the Custom Device Connection.

### Setting Environment Variables in Windows

Variables must be set at **Machine (System) scope** so they are accessible to the Task Scheduler service account that executes the script. User-scope variables are not inherited by scheduled jobs running under a different account.

**Via the GUI**
1. Open **Start**, search for **"Edit the system environment variables"**, and press Enter.
2. In the System Properties dialog, click **Environment Variables…**.
3. Under **System variables**, click **New** for each entry below, then click OK.
4. Click OK on all dialogs to save.

**Via PowerShell (requires an elevated session)**

```powershell
# Run once in an Administrator PowerShell window on the host machine.
# Changes are effective immediately for new processes; no reboot required.

[System.Environment]::SetEnvironmentVariable("ME_CLIENT_ID",     "your_client_id",     "Machine")
[System.Environment]::SetEnvironmentVariable("ME_CLIENT_SECRET",  "your_client_secret",  "Machine")
[System.Environment]::SetEnvironmentVariable("ME_REFRESH_TOKEN",  "your_refresh_token",  "Machine")
[System.Environment]::SetEnvironmentVariable("DRATA_API_TOKEN",   "your_drata_token",    "Machine")
```

Verify each value after setting:

```powershell
[System.Environment]::GetEnvironmentVariable("ME_CLIENT_ID", "Machine")
```

**Security notes**
- Never set these values inside the script file or in any file committed to source control.
- After rotating any credential, update the environment variable on the host and confirm the next sync log reflects a successful token acquisition.
- For higher-assurance environments, consider retrieving secrets at runtime from **AWS Secrets Manager** or **Azure Key Vault** and injecting them into the script's variables, rather than persisting them as machine-level environment variables.

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
