# SPEC: 
# ManageEngine Endpoint Central to Drata Custom Device Connection
**Execution Assumption:** Windows EC2 (on-premises ManageEngine instance)

---

## 1. Objective

Pull device compliance data from ManageEngine Endpoint Central (on-prem, Windows EC2) and deliver it as a JSON payload to Drata's Custom Device Connection endpoint, using a scheduled PowerShell script as the sole orchestration layer. The integration must populate five compliance dimensions per device, plus two identity-binding fields.

---

## 2. Required Data Points

| # | Drata Field | ManageEngine Source | Retrieval Method |
|---|---|---|---|
| 1 | User email | `agent_logged_on_users` / `ownerEmailID` | SOM Computers API |
| 2 | Device serial number | `servicetag` or `resource_id` | SOM Computers API |
| 3 | OS auto-update status | Patch status endpoint | Patch Management API |
| 4 | Antivirus / EDR presence | Installed software list | Inventory Software API |
| 5 | Password manager presence | Installed software list | Inventory Software API |
| 6 | Hard drive encryption | BitLocker protection status | Scheduled CSV Report |
| 7 | Screen lock timeout | Screen saver/lock policy | Scheduled CSV Report |

> **Report format note:** Per ManageEngine documentation on-prem scheduled reports export as **CSV, XLSX, or PDF**.

---

## 3. ManageEngine API Authentication (On-Premises)

ManageEngine Endpoint Central on-prem supports static API token authentication. The token is generated once and reused on every script run.

**Token generation:** Admin console > Admin > Integrations > API Explorer > Authentication > Execute.  
Copy the `auth_token` value from the response. Store it as a Windows environment variable or in a secrets manager. Do not hardcode it in the script.

**Required role permissions:** `SOM_Read`, `Inventory_Read`, `Report_Read`, `PatchMgmt_Read`.

All subsequent API calls pass the token via the `Authorization` header:

```
GET http://<ME_SERVER>:<PORT>/api/1.4/som/computers
Authorization: <auth_token>
Content-Type: application/json
```

---

## 4. PowerShell Data Collection Logic

The script executes the following steps in sequence.

### Step 1: Pull All Managed Computers

```
GET /api/1.4/som/computers
```

Returns a paginated array. Key fields used: `resource_id`, `resource_name`, `servicetag` (serial), `agent_logged_on_users`, `ownerEmailID`, `os_version`, `os_name`.  
Paginate using `?page=N&pagelimit=100` until `total` is exhausted.

### Step 2: Pull Installed Software per Device

```
GET /api/1.4/inventory/computerinstalledsoftware?resid=<resource_id>
```

For each device, scan the returned software name list for known AV/EDR strings (e.g., "CrowdStrike", "Defender", "Sentinel", "Carbon Black") and known password manager strings (e.g., "1Password", "LastPass", "Bitwarden", "Keeper"). Match is case-insensitive substring. 
The compliance team must provide the approved product list to finalize these match strings.

### Step 3: Pull OS Patch Status

```
GET /api/1.4/patch/allsystemdetails?resid=<resource_id>
```

Evaluate whether the device has outstanding critical or security patches. A device with zero missing critical patches is considered OS-update compliant.

### Step 4: Consume BitLocker and Screen Lock CSV Reports

These two data points are **not exposed via the REST API** in Endpoint Central v1.4 on-premises. They are only available via the Reports module.

**Configuration required (one-time):**

1. In Endpoint Central, navigate to Reports > BitLocker Reports > Encryption Status. Schedule this report to export as CSV to a local file path on the EC2 instance at a frequency aligned with the script run schedule (recommend: one hour before the script fires).
2. Similarly, schedule a Custom Report or Query Report for screen lock / screensaver policy status, exported as CSV to the same directory.

**PowerShell CSV parsing:**

```powershell
$bitlockerData = Import-Csv -Path "C:\DrataSync\reports\bitlocker_export.csv"
$screenLockData = Import-Csv -Path "C:\DrataSync\reports\screenlock_export.csv"
```

The BitLocker CSV will contain columns including `Computer Name`, `Protection Status` (values: "Protected" / "Unprotected"), `Volume Status` ("Fully Encrypted" / "Fully Decrypted" / "Partially Encrypted"), and `Encryption Method`.

Map `Protection Status == "Protected"` to `diskEncryption: true`. All other values map to `false`.

Map screen lock based on the idle timeout value. The compliance team must define the acceptable maximum timeout (recommended: 900 seconds / 15 minutes). Devices at or below the threshold map to `screenLock: true`.

> **Field name caveat:** The actual column headers in the exported CSV depend on the specific ManageEngine version deployed. Must validate column names against a live export before finalizing the PowerShell field references.

---

## 5. JSON Payload Assembly and Drata Submission

After all data is collected and merged by `resource_id`, the script builds one JSON object per device and POSTs it to the Drata Custom Device Connection endpoint.

### Drata Endpoint

```
POST https://app.drata.com/api/pull/v1/devices
Authorization: Bearer <DRATA_API_TOKEN>
Content-Type: application/json
```

The Drata API token is generated when creating the Custom Device Connection in the Drata UI under Connections > Custom Device. 
Stored alongside the ManageEngine token as an environment variable.

### Payload Schema (per device)

```json
{
  "serialNumber": "S601TLP",
  "email": "francois.monnier@smartcomms.com",
  "osVersion": "Windows 10 Professional Edition (x64)",
  "diskEncryption": true,
  "screenLock": true,
  "autoUpdate": true,
  "antivirus": true,
  "passwordManager": false
}
```

The script iterates the merged device list and POSTs one payload per device. Drata accepts individual device objects, not batch arrays, at this endpoint.

### PowerShell Submission Block

```powershell
$drataToken = $env:DRATA_API_TOKEN
$headers = @{
    "Authorization" = "Bearer $drataToken"
    "Content-Type"  = "application/json"
}

foreach ($device in $mergedDevices) {
    $payload = @{
        serialNumber    = $device.SerialNumber
        email           = $device.UserEmail
        osVersion       = $device.OsVersion
        diskEncryption  = $device.DiskEncrypted
        screenLock      = $device.ScreenLockCompliant
        autoUpdate      = $device.PatchCompliant
        antivirus       = $device.AntivirusPresent
        passwordManager = $device.PasswordManagerPresent
    } | ConvertTo-Json

    Invoke-RestMethod -Uri "https://app.drata.com/api/pull/v1/devices" `
                      -Method POST `
                      -Headers $headers `
                      -Body $payload
}
```

---

## 6. Scheduling and Maintenance

| Concern | Recommendation |
|---|---|
| Run frequency | Daily via Windows Task Scheduler. Recommended: 03:00 local time on the EC2 instance. |
| CSV report timing | Schedule ManageEngine CSV exports to complete by 02:30, before the script fires. |
| Logging | Write per-run logs to `C:\DrataSync\logs\`. Retain 30 days. Log device count, success count, and any HTTP errors. |
| ME version updates | Re-validate CSV column names and API response field names after any ManageEngine upgrade. |
| Product changes | If the organization changes AV, EDR, or password manager products, update the match string arrays in the script. Document this as a change control item. |
| Token rotation | If the ManageEngine API token or Drata API token is rotated, update the environment variables on the EC2 instance. The script itself does not need to change. |

---

## 7. Items Requiring Input

1. **Approved AV/EDR product name strings** for software matching.
2. **Approved password manager product name strings** for software matching.
3. **Maximum screen lock timeout threshold** (in seconds) that constitutes compliant.
4. **Confirmation of CSV column headers** from a live ManageEngine export for both BitLocker and screen lock reports.
5. **User email field confirmation**: Ensure `ownerEmailID` or `agent_logged_on_users` reliably contains the user's organizational email address in the SmartComms deployment. This is the field that maps the device to a Drata personnel record.
